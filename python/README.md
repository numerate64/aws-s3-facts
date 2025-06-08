# AWS S3 Bucket Summary

A Python script that provides a comprehensive overview of your AWS S3 storage usage, including detailed breakdown by storage class, object counts, and storage capacities.

## Features

- Analyzes all S3 buckets in your AWS account
- Shows detailed storage usage by storage class (STANDARD, GLACIER, GLACIER_IR, etc.)
- Provides both per-bucket and total storage statistics
- Shows object counts and total capacity per storage class
- Human-readable size formatting (B, KB, MB, GB, TB, PB)
- Progress tracking with estimated time remaining
- Detailed console output and CSV export
- AWS profile support for multiple account management
- Timeout handling for large buckets

## Prerequisites

- Python 3.6 or later
- AWS account with appropriate S3 permissions
- AWS credentials configured (via AWS CLI or environment variables)
- Required Python packages: boto3, botocore

## Installation

1. Clone or download this repository
2. Install required dependencies:
   ```bash
   pip install boto3 botocore
   ```
3. Configure AWS credentials using one of these methods:
   - Run `aws configure`
   - Set environment variables: `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY`
   - Use an AWS credentials file

## Usage

Basic usage:
```bash
python s3_bucket_summary.py
```

### Command Line Options

- `--profile`: Specify AWS profile name (optional)
  ```bash
  python s3_bucket_summary.py --profile myprofile
  ```

## Output

The script generates two types of output:

### 1. Console Output

Shows a summary of your S3 storage usage, including:
- Total number of buckets
- Total number of objects
- Total storage size (human-readable)
- Storage class distribution (object counts and sizes)
- Largest bucket information

Example output:
```
=== S3 Storage Summary ===
Total Buckets: 13
Total Objects: 46,059
Total Size: 37.7 GB

Storage Class Distribution:
  GLACIER: 174 objects (986.4 MB)
  GLACIER_IR: 105 objects (10.2 GB)
  STANDARD: 45,780 objects (26.6 GB)

Largest Bucket: aws-cloudtrail-logs-misfirm
  Objects: 37,742
  Size: 137.7 MB
```

### 2. CSV Output (s3_bucket_summary.csv)

Contains detailed information in CSV format, including:
- Per-bucket details (name, object count, size, storage classes)
- Summary statistics
- Detailed storage class distribution with object counts and sizes

## Timeout Handling

The script includes a 15-minute timeout by default to prevent excessive runtime. You can modify this by changing the `timeout_minutes` parameter in the `get_s3_summary()` function.

## Error Handling

- Handles missing or invalid AWS credentials
- Continues processing other buckets if one is inaccessible
- Provides meaningful error messages for common issues

## License

This project is licensed under the MIT License - see the LICENSE file for details.