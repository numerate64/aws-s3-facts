# AWS S3 Storage Analyzer

A PowerShell script that provides a comprehensive overview of your AWS S3 storage usage, including detailed breakdown by storage class and object counts.

## Features
- Analyzes all S3 buckets in the specified region
- Shows storage usage by storage class (STANDARD, GLACIER, GLACIER_IR, etc.)
- Provides both per-bucket and total storage statistics
- Displays object counts per storage class
- Automatically formats storage sizes (KB, MB, GB)
- Shows progress during execution
- Exports results to CSV for further analysis

## Prerequisites
- PowerShell 7 or later
- AWS account with appropriate S3 permissions
- Internet connection

## Installation
1. Clone or download this repository
2. No additional installation required - the script will automatically install required AWS PowerShell modules

## Usage
```powershell
.\AwsS3BucketReport.ps1
```

### Optional Parameters
- `-AccessKey`: AWS Access Key ID (will prompt if not provided)
- `-SecretKey`: AWS Secret Access Key (will prompt if not provided)
- `-Region`: AWS region (default: us-east-1)

Example with parameters:
```powershell
.\AwsS3BucketReport.ps1 -Region us-west-2
```

## Output

### Console Output
1. Progress bar showing current bucket being processed
2. Summary table showing all buckets with their storage usage
3. Grand totals for all buckets
4. Detailed storage breakdown by class

Example summary:
```
Summary:
- 13 buckets
- 45,019 objects total
- 37.71 GB total storage

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
