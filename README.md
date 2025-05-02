# AWS S3 Facts

This PowerShell project connects to your AWS account and provides information about your S3 buckets, including their names, the number of objects, and the current capacity and object count in each storage tier (storage class).

## Prerequisites
- PowerShell 7+
- Internet connection

## How It Works
- The script will automatically install the AWS.Tools.S3 module if it is not already installed.
- You will be prompted for your AWS Access Key ID and Secret Access Key (these are not stored and are hidden during input).
- The script connects to AWS and summarizes the storage usage for each S3 bucket by storage class.
- All unique storage classes (e.g., STANDARD, GLACIER, DEEP_ARCHIVE, etc.) found across all buckets will appear as columns in the output table and CSV, even if only one bucket contains that class.
- For each storage class, both the total storage and the number of objects in that tier are displayed (e.g., `STANDARD`, `STANDARD_ObjectCount`, `GLACIER`, `GLACIER_ObjectCount`).
- Capacity values are automatically formatted as KB, MB, or GB for readability.
- Debug output will show the first few objects and all storage classes found in each bucket.

## Installation
1. Clone or copy this project folder to your machine.
2. No manual dependency installation is required; the script handles it.

## Usage
1. Open PowerShell and navigate to the `aws-s3-facts` directory.
2. Run the script:
   ```powershell
   .\AwsS3BucketReport.ps1
   ```
   - Optionally, you can provide parameters:
     ```powershell
     .\AwsS3BucketReport.ps1 -AccessKey "YOUR_ACCESS_KEY" -SecretKey "YOUR_SECRET_KEY" -Region "us-east-1"
     ```
   - If not provided, you will be securely prompted for your AWS credentials.

## Output
- The script will display a table with each bucket's name, the number of objects (`ObjectCount`), the total storage for each storage class, and the number of objects per storage class (e.g., `STANDARD_ObjectCount`). Storage values are shown in the most appropriate unit (KB, MB, or GB).
- The script will also output the results to a CSV file `s3-bucket-summary.csv` in the current directory. All storage classes found will be included as columns, as well as `ObjectCount` and per-tier object counts.
- At the end, a summary is printed with the total number of buckets, total number of objects, and total storage (in the most appropriate unit) across all buckets and classes.
- Debug output will show the first three objects in each bucket and all storage classes detected.

---
**Note:** For large buckets, this script may take some time to run as it enumerates all objects to sum their sizes by storage class.

**Security:** Your AWS credentials are only used for the session and are not stored. Input is hidden for security.
