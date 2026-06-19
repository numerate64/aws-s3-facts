# Python S3 Bucket Summary

`s3_bucket_summary.py` scans buckets concurrently and calculates exact object
counts and object bytes for every observed S3 storage class. A live progress
bar shows completed buckets plus object and byte counts for active scans.

## Requirements

- Python 3.10+
- `boto3`
- AWS permissions listed in the repository README

```sh
python -m pip install boto3
```

## Usage

```sh
python s3_bucket_summary.py --profile my-profile --workers 8
```

Use fewer workers if the account is being throttled. Use more workers when
there are many independent buckets and available network capacity.

```text
--profile NAME       AWS named profile; omit for the normal credential chain
--workers NUMBER     Concurrent bucket scans (default: 8)
--output PATH        CSV path (default: s3_bucket_summary.csv)
--requester-pays     Send RequestPayer=requester
```

## Accuracy

The script sums each object's `Size` under that object's `StorageClass`. It
does not estimate tier capacity from object counts. The report covers current
objects only; object versions and delete markers are not included.

## Tests

```sh
python -m unittest -v
```
