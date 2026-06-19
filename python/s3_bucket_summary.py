#!/usr/bin/env python3
"""Fast, exact S3 object count and storage-class capacity report."""

from __future__ import annotations

import argparse
import csv
import datetime as dt
import sys
import threading
import time
from collections import defaultdict
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable, Iterable, TextIO

import boto3
from botocore.config import Config
from botocore.exceptions import (
    BotoCoreError,
    ClientError,
    NoCredentialsError,
    PartialCredentialsError,
    ProfileNotFound,
)


@dataclass
class TierUsage:
    object_count: int = 0
    size_bytes: int = 0


@dataclass
class BucketUsage:
    bucket_name: str
    region: str = ""
    object_count: int = 0
    size_bytes: int = 0
    tiers: dict[str, TierUsage] = field(default_factory=dict)
    error: str = ""
    elapsed_seconds: float = 0.0


_thread_local = threading.local()
_client_create_lock = threading.Lock()


class ProgressReporter:
    """Thread-safe terminal progress for concurrent bucket scans."""

    def __init__(
        self,
        total: int,
        stream: TextIO = sys.stdout,
        width: int = 28,
        refresh_seconds: float = 0.5,
        interactive: bool | None = None,
    ) -> None:
        self.total = total
        self.stream = stream
        self.width = width
        self.refresh_seconds = refresh_seconds
        self.interactive = stream.isatty() if interactive is None else interactive
        self.completed = 0
        self.active: dict[str, tuple[int, int]] = {}
        self.last_rendered = 0.0
        self.lock = threading.Lock()

    def start(self) -> None:
        with self.lock:
            self._render_locked(force=True)

    def update(self, bucket_name: str, object_count: int, size_bytes: int) -> None:
        with self.lock:
            self.active[bucket_name] = (object_count, size_bytes)
            self._render_locked()

    def complete(self, result: BucketUsage) -> None:
        with self.lock:
            self.completed += 1
            self.active.pop(result.bucket_name, None)
            message = self._completion_message(result)
            if self.interactive:
                self.stream.write("\r\033[2K")
            self.stream.write(message + "\n")
            self._render_locked(force=True)

    def finish(self) -> None:
        with self.lock:
            if self.interactive:
                self._render_locked(force=True)
                self.stream.write("\n")
                self.stream.flush()

    def _completion_message(self, result: BucketUsage) -> str:
        prefix = f"[{self.completed}/{self.total}] {result.bucket_name}:"
        if result.error:
            return f"{prefix} ERROR {result.error}"
        return (
            f"{prefix} {result.object_count:,} objects, "
            f"{format_size(result.size_bytes)} in {result.elapsed_seconds:.1f}s"
        )

    def _render_locked(self, force: bool = False) -> None:
        if not self.interactive:
            return

        now = time.monotonic()
        if not force and now - self.last_rendered < self.refresh_seconds:
            return
        self.last_rendered = now

        ratio = self.completed / self.total if self.total else 1.0
        filled = min(self.width, int(self.width * ratio))
        bar = "█" * filled + "░" * (self.width - filled)
        line = (
            f"\r\033[2KBuckets [{bar}] {self.completed}/{self.total} "
            f"({ratio * 100:5.1f}%)"
        )

        if self.active:
            bucket_name, (object_count, size_bytes) = max(
                self.active.items(),
                key=lambda item: item[1][0],
            )
            if len(bucket_name) > 32:
                bucket_name = f"{bucket_name[:29]}..."
            spinner = "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"[int(now * 10) % 10]
            line += (
                f" | {spinner} {bucket_name}: "
                f"{object_count:,} objects, {format_size(size_bytes)}"
            )

        self.stream.write(line)
        self.stream.flush()


def format_size(size_bytes: int) -> str:
    value = float(size_bytes)
    for unit in ("B", "KiB", "MiB", "GiB", "TiB", "PiB"):
        if value < 1024 or unit == "PiB":
            return f"{int(value):,} {unit}" if unit == "B" else f"{value:,.2f} {unit}"
        value /= 1024
    return f"{value:,.2f} PiB"


def normalize_region(location: str | None) -> str:
    if not location:
        return "us-east-1"
    if location == "EU":
        return "eu-west-1"
    return location


def create_session(profile_name: str | None) -> boto3.Session:
    return boto3.Session(profile_name=profile_name) if profile_name else boto3.Session()


def get_s3_client(session: boto3.Session, region: str, workers: int):
    """Return one S3 client per worker thread to avoid shared mutable state."""
    clients = getattr(_thread_local, "s3_clients", None)
    if clients is None:
        clients = {}
        _thread_local.s3_clients = clients

    if region not in clients:
        # boto3 Sessions are not thread-safe, so serialize client creation.
        with _client_create_lock:
            clients[region] = session.client(
                "s3",
                region_name=region,
                config=Config(
                    retries={"max_attempts": 10, "mode": "adaptive"},
                    max_pool_connections=max(10, workers * 2),
                    connect_timeout=10,
                    read_timeout=60,
                ),
            )
    return clients[region]


def discover_buckets(session: boto3.Session, workers: int) -> tuple[list[dict], str]:
    s3 = get_s3_client(session, session.region_name or "us-east-1", workers)
    sts = session.client("sts", config=Config(retries={"max_attempts": 5, "mode": "standard"}))
    account_id = sts.get_caller_identity().get("Account", "N/A")
    return s3.list_buckets().get("Buckets", []), account_id


def get_bucket_region(session: boto3.Session, bucket_name: str, workers: int) -> str:
    s3 = get_s3_client(session, session.region_name or "us-east-1", workers)
    response = s3.get_bucket_location(Bucket=bucket_name)
    return normalize_region(response.get("LocationConstraint"))


def scan_bucket(
    session: boto3.Session,
    bucket_name: str,
    workers: int,
    requester_pays: bool = False,
    progress_callback: Callable[[str, int, int], None] | None = None,
) -> BucketUsage:
    """List one bucket once and sum exact object bytes for every storage class."""
    started = time.monotonic()
    result = BucketUsage(bucket_name=bucket_name)

    try:
        if progress_callback:
            progress_callback(bucket_name, 0, 0)
        result.region = get_bucket_region(session, bucket_name, workers)
        s3 = get_s3_client(session, result.region, workers)
        request = {"Bucket": bucket_name, "PaginationConfig": {"PageSize": 1000}}
        if requester_pays:
            request["RequestPayer"] = "requester"

        tier_counts: defaultdict[str, int] = defaultdict(int)
        tier_sizes: defaultdict[str, int] = defaultdict(int)

        for page in s3.get_paginator("list_objects_v2").paginate(**request):
            contents = page.get("Contents", ())
            result.object_count += len(contents)
            for obj in contents:
                storage_class = str(obj.get("StorageClass") or "STANDARD").upper()
                size = int(obj.get("Size") or 0)
                result.size_bytes += size
                tier_counts[storage_class] += 1
                tier_sizes[storage_class] += size
            if progress_callback:
                progress_callback(bucket_name, result.object_count, result.size_bytes)

        result.tiers = {
            name: TierUsage(tier_counts[name], tier_sizes[name])
            for name in sorted(tier_counts)
        }
    except (ClientError, BotoCoreError) as exc:
        result.error = str(exc)
    finally:
        result.elapsed_seconds = time.monotonic() - started

    return result


def scan_all_buckets(
    session: boto3.Session,
    buckets: Iterable[dict],
    workers: int,
    requester_pays: bool = False,
) -> list[BucketUsage]:
    bucket_list = list(buckets)
    results: list[BucketUsage] = []
    total = len(bucket_list)
    progress = ProgressReporter(total)
    progress.start()

    try:
        with ThreadPoolExecutor(max_workers=workers, thread_name_prefix="s3-scan") as executor:
            futures = {
                executor.submit(
                    scan_bucket,
                    session,
                    bucket["Name"],
                    workers,
                    requester_pays,
                    progress.update,
                ): bucket["Name"]
                for bucket in bucket_list
            }

            for future in as_completed(futures):
                result = future.result()
                results.append(result)
                progress.complete(result)
    finally:
        progress.finish()

    return sorted(results, key=lambda item: item.bucket_name.lower())


def aggregate_tiers(results: Iterable[BucketUsage]) -> dict[str, TierUsage]:
    totals: defaultdict[str, TierUsage] = defaultdict(TierUsage)
    for bucket in results:
        if bucket.error:
            continue
        for storage_class, usage in bucket.tiers.items():
            totals[storage_class].object_count += usage.object_count
            totals[storage_class].size_bytes += usage.size_bytes
    return dict(sorted(totals.items()))


def write_csv(results: list[BucketUsage], account_id: str, output_path: Path) -> None:
    tier_names = sorted({tier for bucket in results for tier in bucket.tiers})
    generated_at = dt.datetime.now().astimezone().isoformat(timespec="seconds")
    headers = [
        "AWS Account",
        "Generated At",
        "Bucket Name",
        "Region",
        "Object Count",
        "Total Size (Bytes)",
        "Total Size",
        "Elapsed Seconds",
        "Error",
    ]
    for tier in tier_names:
        headers.extend((f"{tier} Objects", f"{tier} Size (Bytes)", f"{tier} Size"))

    with output_path.open("w", newline="", encoding="utf-8") as output:
        writer = csv.DictWriter(output, fieldnames=headers)
        writer.writeheader()

        for bucket in results:
            row = {
                "AWS Account": account_id,
                "Generated At": generated_at,
                "Bucket Name": bucket.bucket_name,
                "Region": bucket.region,
                "Object Count": bucket.object_count,
                "Total Size (Bytes)": bucket.size_bytes,
                "Total Size": format_size(bucket.size_bytes),
                "Elapsed Seconds": f"{bucket.elapsed_seconds:.3f}",
                "Error": bucket.error,
            }
            for tier in tier_names:
                usage = bucket.tiers.get(tier, TierUsage())
                row[f"{tier} Objects"] = usage.object_count
                row[f"{tier} Size (Bytes)"] = usage.size_bytes
                row[f"{tier} Size"] = format_size(usage.size_bytes)
            writer.writerow(row)

        successful = [bucket for bucket in results if not bucket.error]
        tier_totals = aggregate_tiers(successful)
        total_size = sum(bucket.size_bytes for bucket in successful)
        total_row = {
            "AWS Account": account_id,
            "Generated At": generated_at,
            "Bucket Name": "__ACCOUNT_TOTAL__",
            "Object Count": sum(bucket.object_count for bucket in successful),
            "Total Size (Bytes)": total_size,
            "Total Size": format_size(total_size),
        }
        for tier in tier_names:
            usage = tier_totals.get(tier, TierUsage())
            total_row[f"{tier} Objects"] = usage.object_count
            total_row[f"{tier} Size (Bytes)"] = usage.size_bytes
            total_row[f"{tier} Size"] = format_size(usage.size_bytes)
        writer.writerow(total_row)


def print_summary(results: list[BucketUsage], account_id: str) -> None:
    successful = [bucket for bucket in results if not bucket.error]
    total_objects = sum(bucket.object_count for bucket in successful)
    total_size = sum(bucket.size_bytes for bucket in successful)
    tiers = aggregate_tiers(successful)

    print(f"\nAWS Account: {account_id}")
    print("=== S3 Storage Summary ===")
    print(f"Buckets scanned: {len(successful):,}/{len(results):,}")
    print(f"Total objects:   {total_objects:,}")
    print(f"Total capacity:  {format_size(total_size)} ({total_size:,} bytes)")
    print("\nStorage class / tier:")
    for name, usage in tiers.items():
        print(
            f"  {name:<24} {usage.object_count:>15,} objects  "
            f"{format_size(usage.size_bytes):>14}  ({usage.size_bytes:,} bytes)"
        )

    errors = [bucket for bucket in results if bucket.error]
    if errors:
        print(f"\nBuckets with errors: {len(errors)}", file=sys.stderr)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Count S3 objects and sum exact capacity by S3 storage class."
    )
    parser.add_argument("--profile", help="AWS named profile (default: normal credential chain)")
    parser.add_argument(
        "--workers",
        type=int,
        default=8,
        help="Buckets scanned concurrently (default: 8)",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=Path("s3_bucket_summary.csv"),
        help="CSV output path",
    )
    parser.add_argument(
        "--requester-pays",
        action="store_true",
        help="Set RequestPayer=requester when listing buckets",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.workers < 1:
        print("--workers must be at least 1", file=sys.stderr)
        return 2

    started = time.monotonic()
    try:
        session = create_session(args.profile)
        buckets, account_id = discover_buckets(session, args.workers)
        print(f"Found {len(buckets):,} buckets; scanning with {args.workers} workers...")
        results = scan_all_buckets(
            session,
            buckets,
            args.workers,
            requester_pays=args.requester_pays,
        )
        write_csv(results, account_id, args.output)
        print_summary(results, account_id)
        print(f"\nCSV written to {args.output}")
        print(f"Completed in {time.monotonic() - started:.1f}s")
        return 1 if any(bucket.error for bucket in results) else 0
    except (NoCredentialsError, PartialCredentialsError, ProfileNotFound) as exc:
        print(f"AWS credential error: {exc}", file=sys.stderr)
        return 2
    except (ClientError, BotoCoreError) as exc:
        print(f"AWS API error: {exc}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print("\nCancelled.", file=sys.stderr)
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
