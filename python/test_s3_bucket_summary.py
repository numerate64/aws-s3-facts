import csv
import datetime as dt
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


class FakeCloudWatchPaginator:
    def paginate(self, **request):
        return [
            {
                "Metrics": [
                    {
                        "Dimensions": [
                            {"Name": "BucketName", "Value": "example-bucket"},
                            {"Name": "StorageType", "Value": "StandardStorage"},
                        ]
                    },
                    {
                        "Dimensions": [
                            {"Name": "BucketName", "Value": "example-bucket"},
                            {"Name": "StorageType", "Value": "GlacierStorage"},
                        ]
                    },
                ]
            }
        ]


class FakeCloudWatchClient:
    def get_paginator(self, operation):
        self.operation = operation
        return FakeCloudWatchPaginator()

    def get_metric_data(self, **request):
        timestamp = dt.datetime(2026, 6, 18, tzinfo=dt.timezone.utc)
        results = []
        for query in request["MetricDataQueries"]:
            metric = query["MetricStat"]["Metric"]
            dimensions = {
                item["Name"]: item["Value"] for item in metric["Dimensions"]
            }
            if metric["MetricName"] == "NumberOfObjects":
                value = 42
            elif dimensions["StorageType"] == "StandardStorage":
                value = 1_000
            else:
                value = 9_000
            results.append(
                {
                    "Id": query["Id"],
                    "Values": [value],
                    "Timestamps": [timestamp],
                }
            )
        return {"MetricDataResults": results}


class FakeSession:
    def __init__(self):
        self.cloudwatch = FakeCloudWatchClient()

    def client(self, service_name, **kwargs):
        if service_name != "cloudwatch":
            raise AssertionError(service_name)
        return self.cloudwatch


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

    def test_fast_cloudwatch_summary_uses_daily_aggregate_metrics(self):
        with patch.object(
            report,
            "get_bucket_regions",
            return_value=({"example-bucket": "us-east-1"}, {}),
        ):
            results = report.get_cloudwatch_summary(
                FakeSession(),
                [{"Name": "example-bucket"}],
                workers=4,
            )

        self.assertEqual(1, len(results))
        result = results[0]
        self.assertEqual(42, result.object_count)
        self.assertEqual(10_000, result.size_bytes)
        self.assertEqual(1_000, result.tiers["STANDARD"].size_bytes)
        self.assertEqual(9_000, result.tiers["GLACIER"].size_bytes)
        self.assertFalse(result.tier_counts_available)
        self.assertEqual("2026-06-18T00:00:00+00:00", result.metric_timestamp)

    def test_storage_type_mapping_groups_cloudwatch_overhead(self):
        self.assertEqual(
            "DEEP_ARCHIVE",
            report.storage_type_to_tier("DeepArchiveObjectOverhead"),
        )
        self.assertEqual(
            "INTELLIGENT_TIERING_AA",
            report.storage_type_to_tier("IntAAObjectOverhead"),
        )

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
