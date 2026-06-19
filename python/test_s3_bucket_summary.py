import csv
import io
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import s3_bucket_summary as report


class FakePaginator:
    def paginate(self, **request):
        self.request = request
        return [
            {
                "Contents": [
                    {"Size": 100, "StorageClass": "STANDARD"},
                    {"Size": 900, "StorageClass": "GLACIER"},
                ]
            },
            {
                "Contents": [
                    {"Size": 50},
                    {"Size": 2_000, "StorageClass": "DEEP_ARCHIVE"},
                ]
            },
        ]


class FakeS3Client:
    def __init__(self):
        self.paginator = FakePaginator()

    def get_paginator(self, operation):
        self.operation = operation
        return self.paginator


class S3BucketSummaryTests(unittest.TestCase):
    def test_scan_bucket_sums_exact_bytes_per_storage_class(self):
        client = FakeS3Client()
        progress_updates = []

        with (
            patch.object(report, "get_bucket_region", return_value="us-east-1"),
            patch.object(report, "get_s3_client", return_value=client),
        ):
            result = report.scan_bucket(
                object(),
                "example-bucket",
                workers=4,
                progress_callback=lambda name, count, size: progress_updates.append(
                    (name, count, size)
                ),
            )

        self.assertEqual("list_objects_v2", client.operation)
        self.assertEqual(4, result.object_count)
        self.assertEqual(3_050, result.size_bytes)
        self.assertEqual(2, result.tiers["STANDARD"].object_count)
        self.assertEqual(150, result.tiers["STANDARD"].size_bytes)
        self.assertEqual(900, result.tiers["GLACIER"].size_bytes)
        self.assertEqual(2_000, result.tiers["DEEP_ARCHIVE"].size_bytes)
        self.assertEqual(
            [
                ("example-bucket", 0, 0),
                ("example-bucket", 2, 1_000),
                ("example-bucket", 4, 3_050),
            ],
            progress_updates,
        )

    def test_progress_reporter_shows_bar_and_active_bucket(self):
        stream = io.StringIO()
        progress = report.ProgressReporter(
            total=2,
            stream=stream,
            interactive=True,
            refresh_seconds=0,
        )

        progress.start()
        progress.update("large-example-bucket", 12_345, 9_876_543)
        progress.complete(
            report.BucketUsage(
                "small-bucket",
                object_count=3,
                size_bytes=100,
                elapsed_seconds=0.5,
            )
        )
        progress.finish()

        output = stream.getvalue()
        self.assertIn("Buckets [", output)
        self.assertIn("1/2", output)
        self.assertIn("large-example-bucket", output)
        self.assertIn("12,345 objects", output)

    def test_aggregate_tiers_combines_bucket_totals(self):
        results = [
            report.BucketUsage(
                "one",
                tiers={"STANDARD": report.TierUsage(2, 100)},
            ),
            report.BucketUsage(
                "two",
                tiers={
                    "STANDARD": report.TierUsage(3, 200),
                    "GLACIER": report.TierUsage(1, 500),
                },
            ),
        ]

        totals = report.aggregate_tiers(results)

        self.assertEqual(report.TierUsage(5, 300), totals["STANDARD"])
        self.assertEqual(report.TierUsage(1, 500), totals["GLACIER"])

    def test_csv_has_one_valid_header_row(self):
        results = [
            report.BucketUsage(
                "one",
                region="us-east-1",
                object_count=1,
                size_bytes=123,
                tiers={"STANDARD": report.TierUsage(1, 123)},
            )
        ]

        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "report.csv"
            report.write_csv(results, "123456789012", output)
            with output.open(newline="", encoding="utf-8") as stream:
                rows = list(csv.DictReader(stream))

        self.assertEqual(2, len(rows))
        self.assertEqual("123456789012", rows[0]["AWS Account"])
        self.assertEqual("123", rows[0]["STANDARD Size (Bytes)"])
        self.assertEqual("__ACCOUNT_TOTAL__", rows[1]["Bucket Name"])
        self.assertEqual("123", rows[1]["Total Size (Bytes)"])


if __name__ == "__main__":
    unittest.main()
