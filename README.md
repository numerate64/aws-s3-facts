# AWS S3 Facts

Fast S3 object-count and capacity reports for Python and PowerShell. The
default mode reads AWS's precomputed daily CloudWatch storage metrics in
seconds. An exact mode remains available when current object-level data is
required.

## Improvements

- Exact byte totals per S3 storage class; no proportional size estimates.
- Fast CloudWatch mode is now the default and does not list object keys.
- Bounded bucket-level concurrency (`8` workers by default).
- Maximum S3 page size (`1,000` objects per request).
- Streaming aggregation with no retained object list.
- Live bucket progress bar with object and byte counts for long-running scans.
- One bucket-location lookup and one paginated listing per bucket.
- Adaptive retries in Python and AWS CLI automatic pagination in PowerShell.
- Partial failures are reported without discarding successful bucket results.

Fast mode usually completes in seconds regardless of object count. Its daily
metrics include current and noncurrent versions, delete markers, incomplete
multipart uploads, and storage-class overhead. Exact mode is proportional to
the number of current objects because it reads every object's `Size` and
`StorageClass`.

## Required IAM permissions

- `s3:ListAllMyBuckets`
- `s3:GetBucketLocation`
- `s3:ListBucket` on each bucket to report
- `sts:GetCallerIdentity`
- `cloudwatch:ListMetrics`
- `cloudwatch:GetMetricData`

## Python

Requires Python 3.10+ and boto3:

```sh
python -m pip install boto3
python python/s3_bucket_summary.py --profile my-profile
```

Options:

```text
--profile NAME       AWS named profile; omit for the normal credential chain
--mode fast|exact    Daily CloudWatch metrics or current object listing
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
    -Mode Fast `
    -Workers 8 `
    -OutputPath s3-report.csv
```

Use `-Mode Exact` to list current objects and calculate per-tier object counts.

`AwsS3BucketReport.ps1` and `AwsS3BucketReport_New.ps1` remain as compatibility
entry points and invoke the optimized `SimpleS3Report.ps1`. The `_orig` file is
retained as a historical copy.

## Output

The console summary and CSV include:

- Object count and total bytes for every bucket.
- Exact object count and bytes for each observed S3 storage class.
- Bucket region, creation date, elapsed time, and access errors.
- Account-wide totals by storage class.

Fast mode reports total object count and capacity by CloudWatch storage tier.
Standard CloudWatch S3 metrics do not provide object count per tier, so those
CSV fields are blank and console output shows `N/A`. Exact mode reports current
object count per storage class and logical object bytes, but excludes
noncurrent versions and delete markers.
