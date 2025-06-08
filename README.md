# AWS S3 Storage Analyzer

A comprehensive set of tools for analyzing AWS S3 storage usage across your AWS accounts. This repository includes both PowerShell and Python implementations.

## Project Structure

```
aws-s3-facts/
├── python/                    # Python implementation
│   ├── s3_bucket_summary.py    # Main Python script
│   └── README.md              # Python-specific documentation
└── README.md                  # This file
```

## Features

### Common Features (both implementations)
- Analyze all S3 buckets in your AWS account
- Show storage usage by storage class (STANDARD, GLACIER, GLACIER_IR, etc.)
- Provide both per-bucket and total storage statistics
- Display object counts and total capacity per storage class
- Export results to CSV for further analysis

### Python Implementation (`/python`)
- Human-readable size formatting (B, KB, MB, GB, TB, PB)
- Progress tracking with estimated time remaining
- Detailed console output and CSV export
- AWS profile support for multiple account management
- Timeout handling for large buckets
- Identifies both largest bucket (by object count) and highest capacity bucket (by size)

## Prerequisites

### For Python Version
- Python 3.6 or later
- AWS account with appropriate S3 permissions
- Required Python packages: boto3, botocore

## Installation

### Python Version
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

### Python Version
Basic usage:
```bash
python s3_bucket_summary.py
```

#### Command Line Options
- `--profile`: Specify AWS profile name (optional)
  ```bash
  python s3_bucket_summary.py --profile myprofile
  ```

## Output

### Python Version
Generates two types of output:
1. **Console Output**: Summary of S3 storage usage
2. **CSV File**: Detailed report in `s3_bucket_summary.csv`

Example console output:
```
=== S3 Storage Summary ===
Total Buckets: 13
Total Objects: 49,402
Total Size: 38.0 GB

Storage Class Distribution:
  GLACIER: 174 objects (983.5 MB)
  GLACIER_IR: 111 objects (10.5 GB)
  STANDARD: 49,117 objects (26.6 GB)

Highest Capacity Bucket (by size): example-bucket
  Size: 20.7 GB
  Objects: 3,753

Largest Bucket (by object count): logs-bucket
  Objects: 41,066
  Size: 156.6 MB
```

## Contributing

1. Fork the repository
2. Create a feature branch
3. Commit your changes
4. Push to the branch
5. Create a new Pull Request

Storage by Class:
- STANDARD   :   21.24 GB storage in  44739 objects
- GLACIER_IR :   10.19 GB storage in    105 objects
- GLACIER    :    6.28 GB storage in    174 objects
```

### CSV Output
Detailed results are saved to `s3-bucket-summary.csv` in the current directory, including:
- Bucket name
- Total object count
- Storage usage per class
- Object count per class

## Performance Notes
- The script processes each bucket sequentially
- Processing time depends on the number of buckets and objects
- A progress bar shows the current status
- Large buckets may take several minutes to process

## Security
- AWS credentials are only used for the current session
- Credential input is hidden
- No sensitive data is stored to disk
- Uses official AWS SDK for PowerShell

## Example Output
```
BucketName                                                    ObjectCount GLACIER GLACIER_ObjectCount GLACIER_IR GLACIER_IR_ObjectCount STANDARD STANDARD_ObjectCount
----------                                                    ----------- ------- ------------------- ---------- --------------------- -------- --------------------
aq-rubrik-glacier-test                                                  3 0 KB                   0 599.88 MB                   3 0 KB                  0
aws-cloudtrail-logs-misfirm                                         36702 0 KB                   0 0 KB                       0 133.99 MB          36702
...

Summary:
- 13 buckets
- 45,019 objects total
- 37.71 GB total storage

Storage by Class:
- STANDARD   :   21.24 GB storage in  44739 objects
- GLACIER_IR :   10.19 GB storage in    105 objects
- GLACIER    :    6.28 GB storage in    174 objects
```

## License
This project is open source and available under the MIT License.
