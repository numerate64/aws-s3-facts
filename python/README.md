# Python S3 Bucket Summary

`s3_bucket_summary.py` uses daily CloudWatch S3 storage metrics by default, so
runtime is independent of the number of object keys. Exact object scanning is
available when current object-level results are required.

## Requirements

- Python 3.10+
- `boto3`
- AWS permissions listed in the repository README

```sh
python -m pip install boto3
```

## Usage

```sh
python s3_bucket_summary.py --profile my-profile
```

Use fewer workers if the account is being throttled. Use more workers when
there are many independent buckets and available network capacity.

```text
--profile NAME       AWS named profile; omit for the normal credential chain
--mode fast|exact    Daily CloudWatch metrics or current object listing
--workers NUMBER     Concurrent bucket scans (default: 8)
--output PATH        CSV path (default: s3_bucket_summary.csv)
--requester-pays     Send RequestPayer=requester
```

For current object-level results:

```sh
python s3_bucket_summary.py --mode exact --workers 8
```

Exact mode displays a live progress bar with object and byte counts for
long-running buckets.

## Accuracy and freshness

Fast mode uses daily CloudWatch metrics. Total object count includes current
and noncurrent versions, delete markers, and incomplete multipart-upload
parts. Capacity includes object bytes, metadata, minimum-size overhead, and
incomplete uploads. CloudWatch does not expose object count per storage tier.

Exact mode sums each current object's `Size` under its `StorageClass`; it does
not include versions or delete markers.

## Tests

```sh
python -m unittest -v
```
