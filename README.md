# AWS S3 Facts

Fast, exact S3 object-count and capacity reports for Python and PowerShell.
Both implementations list object metadata, sum the real object size for each
storage class, scan multiple buckets concurrently, and export a flat CSV.

## Improvements

- Exact byte totals per S3 storage class; no proportional size estimates.
- Bounded bucket-level concurrency (`8` workers by default).
- Maximum S3 page size (`1,000` objects per request).
- Streaming aggregation with no retained object list.
- One bucket-location lookup and one paginated listing per bucket.
- Adaptive retries in Python and AWS CLI automatic pagination in PowerShell.
- Partial failures are reported without discarding successful bucket results.

Runtime is proportional to the number of objects because exact current totals
require every object's `Size` and `StorageClass` metadata. Increasing workers
helps when an account has multiple buckets; it cannot split one bucket's key
namespace into safe arbitrary ranges.

## Required IAM permissions

- `s3:ListAllMyBuckets`
- `s3:GetBucketLocation`
- `s3:ListBucket` on each bucket to report
- `sts:GetCallerIdentity`

## Python

Requires Python 3.10+ and boto3:

```sh
python -m pip install boto3
python python/s3_bucket_summary.py --profile my-profile --workers 8
```

Options:

```text
--profile NAME       AWS named profile; omit for the normal credential chain
--workers NUMBER     Concurrent bucket scans (default: 8)
--output PATH        CSV path (default: s3_bucket_summary.csv)
--requester-pays     Send RequestPayer=requester
```

Run tests:

```sh
cd python
python -m unittest -v
```

## PowerShell

Requires AWS CLI v2. PowerShell 7+ enables concurrent scans; PowerShell 5.1
runs the same exact report sequentially.

```powershell
./powershell/SimpleS3Report.ps1 `
    -ProfileName my-profile `
    -Workers 8 `
    -OutputPath s3-report.csv
```

`AwsS3BucketReport.ps1` and `AwsS3BucketReport_New.ps1` remain as compatibility
entry points and invoke the optimized `SimpleS3Report.ps1`. The `_orig` file is
retained as a historical copy.

## Output

The console summary and CSV include:

- Object count and total bytes for every bucket.
- Exact object count and bytes for each observed S3 storage class.
- Bucket region, creation date, elapsed time, and access errors.
- Account-wide totals by storage class.

Object count means current object keys returned by `ListObjectsV2`; it does not
include noncurrent versions or delete markers in versioned buckets. Capacity is
the logical object bytes reported by S3, not billable minimum-size or metadata
overhead for archival classes.
