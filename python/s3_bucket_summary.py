import os
import boto3
import csv
import datetime
import signal
import sys
import configparser
from collections import defaultdict
from botocore.exceptions import NoCredentialsError, PartialCredentialsError, ClientError, ProfileNotFound

class TimeoutException(Exception):
    pass

def timeout_handler(signum, frame):
    raise TimeoutException("Operation timed out while processing buckets")

def format_duration(seconds):
    """Format duration in seconds to a human-readable string."""
    minutes, seconds = divmod(int(seconds), 60)
    hours, minutes = divmod(minutes, 60)
    
    if hours > 0:
        return f"{hours}h {minutes}m {seconds}s"
    elif minutes > 0:
        return f"{minutes}m {seconds}s"
    else:
        return f"{seconds}s"

def get_aws_session(profile_name=None):
    """Create an AWS session using the specified profile or default credentials."""
    try:
        if profile_name:
            session = boto3.Session(profile_name=profile_name)
        else:
            # Try to use the default profile
            session = boto3.Session()
            
        # Test the credentials by getting the caller identity
        sts = session.client('sts')
        identity = sts.get_caller_identity()
        session.account_id = identity.get('Account', 'N/A')
        return session
        
    except (NoCredentialsError, PartialCredentialsError, ProfileNotFound) as e:
        print(f"Error with AWS credentials: {e}")
        print("Please configure AWS CLI using 'aws configure' or set AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY environment variables.")
        return None, None
    except ClientError as e:
        print(f"AWS API error: {e}")
        return None, None

def get_s3_summary(profile_name=None, timeout_minutes=15):
    """Get S3 bucket summary using AWS credentials.
    
    Args:
        profile_name (str, optional): AWS profile name to use. Defaults to None (uses default profile).
        timeout_minutes (int, optional): Maximum time to spend processing (in minutes). Defaults to 15.
    
    Returns:
        tuple: (summary_data, account_id) where summary_data is the list of bucket summaries
               and account_id is the AWS account number.
    """
    try:
        # Set up timeout handler
        signal.signal(signal.SIGALRM, timeout_handler)
        signal.alarm(timeout_minutes * 60)  # Convert minutes to seconds
        
        start_time = datetime.datetime.now()
        processed_buckets = 0
        
        # Get AWS session
        session = get_aws_session(profile_name)
        if not session:
            return [], None
                
        # Get account ID from the session
        account_id = getattr(session, 'account_id', 'N/A')
                
        # Create S3 client using the session
        s3 = session.client('s3')
        buckets = s3.list_buckets()['Buckets']
        total_buckets = len(buckets)
        
        print(f"Found {total_buckets} buckets to process...")
        summary = []

        for i, bucket in enumerate(buckets, 1):
            bucket_name = bucket['Name']
            bucket_start = datetime.datetime.now()
            print(f"\n[{i}/{total_buckets}] Processing bucket: {bucket_name}")
            
            paginator = s3.get_paginator('list_objects_v2')
            page_iterator = paginator.paginate(Bucket=bucket_name)

            object_count = 0
            total_size = 0
            storage_classes = defaultdict(int)
            last_update = datetime.datetime.now()

            try:
                for page in page_iterator:
                    if 'Contents' in page:
                        for obj in page['Contents']:
                            object_count += 1
                            total_size += obj['Size']
                            storage_class = obj.get('StorageClass', 'STANDARD')
                            storage_classes[storage_class] += 1
                            
                            # Show progress every 1000 objects or 5 seconds, whichever comes first
                            current_time = datetime.datetime.now()
                            if object_count % 1000 == 0 or (current_time - last_update).total_seconds() >= 5:
                                elapsed = (current_time - bucket_start).total_seconds()
                                rate = object_count / elapsed if elapsed > 0 else 0
                                print(f"  Processed {object_count:,} objects ({rate:,.1f} objects/sec)", end='\r')
                                last_update = current_time
                                
            except ClientError as e:
                print(f"\nWarning: Could not fully access bucket {bucket_name}: {e}")
                # Continue with partial data if we got any
                if object_count == 0:
                    continue
            
            bucket_time = (datetime.datetime.now() - bucket_start).total_seconds()
            print(f"  Processed {object_count:,} objects in {format_duration(bucket_time)}")
            
            summary.append({
                'Bucket Name': bucket_name,
                'Object Count': object_count,
                'Total Size (Bytes)': total_size,
                'Storage Classes': dict(storage_classes)
            })
            
            processed_buckets += 1
            
            # Estimate remaining time
            if i < total_buckets:
                avg_time_per_bucket = (datetime.datetime.now() - start_time).total_seconds() / i
                remaining_buckets = total_buckets - i
                remaining_time = avg_time_per_bucket * remaining_buckets
                print(f"Estimated time remaining: {format_duration(remaining_time)}")
                
    except TimeoutException as e:
        print(f"\nWarning: {str(e)} Processed {processed_buckets} out of {total_buckets} buckets.")
        if processed_buckets == 0:
            return [], None
    except Exception as e:
        print(f"\nError: {str(e)}")
        if processed_buckets == 0:
            return [], None
    finally:
        # Disable the alarm
        signal.alarm(0)
        
    total_time = (datetime.datetime.now() - start_time).total_seconds()
    print(f"\nProcessed {processed_buckets} buckets in {format_duration(total_time)}")
    
    if not summary:
        print("No bucket data was collected.")
        return [], None
    
    return summary, account_id

def write_summary_to_csv(summary, account_id=None, filename='s3_bucket_summary.csv'):
    """Write the S3 bucket summary to a CSV file.
    
    Args:
        summary (list): List of bucket summaries
        account_id (str, optional): AWS account ID
        filename (str, optional): Output filename. Defaults to 's3_bucket_summary.csv'.
    """
    with open(filename, mode='w', newline='') as file:
        writer = csv.writer(file)
        # Write header
        writer.writerow(['S3 Bucket Summary Report'])
        writer.writerow(['Generated at:', datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')])
        if account_id:
            writer.writerow(['AWS Account:', account_id])
        writer.writerow([''])
        
        # Write detailed bucket information
        writer.writerow(['Detailed Bucket Information'])
        writer.writerow(['Bucket Name', 'Object Count', 'Total Size (Bytes)', 'Storage Classes'])

        # Initialize summary variables
        total_objects = 0
        total_size = 0
        storage_class_objects = defaultdict(int)
        storage_class_sizes = defaultdict(int)
        
        # First pass: collect all storage class sizes
        for entry in summary:
            bucket_size = entry['Total Size (Bytes)']
            bucket_objects = entry['Object Count']
            storage_classes = entry['Storage Classes']
            
            # If we have storage class info, distribute the size proportionally
            if storage_classes and bucket_objects > 0:
                for sc, count in storage_classes.items():
                    storage_class_objects[sc] += count
                    # Calculate proportional size for each storage class
                    proportion = count / bucket_objects
                    storage_class_sizes[sc] += int(bucket_size * proportion)
            else:
                # If no storage class info, count as STANDARD
                storage_class_objects['STANDARD'] += bucket_objects
                storage_class_sizes['STANDARD'] += bucket_size
        
        # Second pass: write bucket details
        for entry in summary:
            writer.writerow([
                entry['Bucket Name'],
                entry['Object Count'],
                entry['Total Size (Bytes)'],
                '; '.join(f"{k}: {v}" for k, v in entry['Storage Classes'].items())
            ])
            
            # Update summary variables
            total_objects += entry['Object Count']
            total_size += entry['Total Size (Bytes)']
        
        # Write summary section
        writer.writerow([''])
        writer.writerow(['Summary'])
        writer.writerow(['Total Buckets', len(summary)])
        writer.writerow(['Total Objects', total_objects])
        writer.writerow(['Total Size (Bytes)', total_size])
        writer.writerow(['Total Size (GB)', round(total_size / (1024**3), 2)])
        
        # Write storage class distribution
        writer.writerow([''])
        writer.writerow(['Storage Class Distribution'])
        for sc in sorted(storage_class_objects.keys()):
            count = storage_class_objects[sc]
            size_bytes = storage_class_sizes[sc]
            size_gb = size_bytes / (1024**3)
            writer.writerow([f'  {sc} Objects', count])
            writer.writerow([f'  {sc} Size (Bytes)', size_bytes])
            writer.writerow([f'  {sc} Size (GB)', round(size_gb, 2)])
        
        # Store for console output
        return {
            'total_buckets': len(summary),
            'total_objects': total_objects,
            'total_size': total_size,
            'storage_class_objects': dict(storage_class_objects),
            'storage_class_sizes': {k: v for k, v in storage_class_sizes.items()}
        }
        
        # Write bucket with most objects
        if summary:
            largest_bucket = max(summary, key=lambda x: x['Object Count'])
            writer.writerow([''])
            writer.writerow(['Largest Bucket by Object Count'])
            writer.writerow(['Bucket Name', 'Object Count'])
            writer.writerow([largest_bucket['Bucket Name'], largest_bucket['Object Count']])

def format_size(size_bytes):
    """Convert size in bytes to human readable format."""
    for unit in ['B', 'KB', 'MB', 'GB', 'TB']:
        if size_bytes < 1024.0 or unit == 'TB':
            if unit == 'B':
                return f"{int(size_bytes):,} {unit}"
            return f"{size_bytes:,.1f} {unit}"
        size_bytes /= 1024.0
    return f"{size_bytes:,.1f} PB"

def print_console_summary(summary, account_id=None, csv_stats=None):
    """Print a summary of the S3 usage to the console."""
    if not summary and not csv_stats:
        print("No S3 buckets found or accessible.")
        return
    
    if csv_stats:
        # Use stats from CSV writing if available (more accurate for storage class sizes)
        total_buckets = csv_stats['total_buckets']
        total_objects = csv_stats['total_objects']
        total_size = csv_stats['total_size']
        storage_class_objects = csv_stats['storage_class_objects']
        storage_class_sizes = csv_stats['storage_class_sizes']
    else:
        # Fallback to calculating from summary
        total_buckets = len(summary)
        total_objects = sum(entry['Object Count'] for entry in summary)
        total_size = sum(entry['Total Size (Bytes)'] for entry in summary)
        
        # Calculate storage class distribution (object counts only)
        storage_class_objects = defaultdict(int)
        storage_class_sizes = defaultdict(int)
        
        for entry in summary:
            bucket_size = entry['Total Size (Bytes)']
            bucket_objects = entry['Object Count']
            storage_classes = entry['Storage Classes']
            
            if storage_classes and bucket_objects > 0:
                for sc, count in storage_classes.items():
                    storage_class_objects[sc] += count
                    # Estimate size proportionally
                    proportion = count / bucket_objects
                    storage_class_sizes[sc] += int(bucket_size * proportion)
            else:
                storage_class_objects['STANDARD'] += bucket_objects
                storage_class_sizes['STANDARD'] += bucket_size
    
    # Find largest bucket by object count
    largest_bucket = None
    if summary:
        largest_bucket = max(summary, key=lambda x: x['Object Count'])
    
    # Print summary
    if account_id:
        print(f"\nAWS Account: {account_id}")
    
    print("\n=== S3 Storage Summary ===")
    print(f"Total Buckets: {total_buckets:,}")
    print(f"Total Objects: {total_objects:,}")
    print(f"Total Size: {format_size(total_size)}")
    
    print("\nStorage Class Distribution:")
    for sc in sorted(storage_class_objects.keys()):
        count = storage_class_objects[sc]
        size = storage_class_sizes[sc]
        print(f"  {sc}: {count:,} objects ({format_size(size)})")
    
    if largest_bucket:
        print(f"\nLargest Bucket: {largest_bucket['Bucket Name']}")
        print(f"  Objects: {largest_bucket['Object Count']:,}")
        print(f"  Size: {format_size(largest_bucket['Total Size (Bytes)'])}")
    
    print("=" * 25)

if __name__ == "__main__":
    import argparse
    import sys
    
    try:
        # Set up command line argument parsing
        parser = argparse.ArgumentParser(description='Generate a summary of S3 bucket usage.')
        parser.add_argument('--profile', type=str, help='AWS profile name to use (default: default profile)')
        args = parser.parse_args()
        
        print("Starting S3 bucket summary...")
        
        # Get the summary using the specified profile or default
        summary, account_id = get_s3_summary(profile_name=args.profile)
        if summary is not None:  # Check if we got a valid response (could be empty list)
            print("Writing summary to CSV...")
            # Get stats from CSV writing to ensure consistency
            csv_stats = write_summary_to_csv(summary, account_id=account_id)
            print("\n=== Summary ===")
            print_console_summary(summary, account_id, csv_stats)
            print("\nSummary written to s3_bucket_summary.csv")
        else:
            print("No summary data was returned. Check your AWS credentials and permissions.")
            sys.exit(1)
            
    except KeyboardInterrupt:
        print("\nOperation cancelled by user.")
        sys.exit(130)
    except Exception as e:
        print(f"\nAn error occurred: {str(e)}", file=sys.stderr)
        sys.exit(1)