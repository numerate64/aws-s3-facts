# AWS S3 Facts

Tools for collecting AWS S3 bucket storage facts and exporting them for review. The repository contains both PowerShell and Python approaches for inventorying buckets, counting objects, grouping capacity by storage class, and writing CSV output.

## What Is In This Repo

- `powershell/` - PowerShell S3 reporting scripts, including full and simplified variants.
- `python/s3_bucket_summary.py` - Python implementation using boto3.
- `python/README.md` - Python-specific notes.

## Requirements

- AWS credentials with permission to list buckets and read object metadata.
- PowerShell plus AWS tooling for the PowerShell scripts, or Python 3 with `boto3` and `botocore` for the Python script.

## Python Usage

```sh
cd python
pip install boto3 botocore
python s3_bucket_summary.py --profile my-profile
```

## Output

The scripts print a storage summary and write CSV output suitable for spreadsheet review. Runtime scales with object count because bucket contents are inspected.
