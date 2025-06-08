# AWS S3 Bucket Report Script
# This script uses AWS Tools for PowerShell to gather S3 bucket information

# Ensure AWS.Tools.Common is imported
try {
    # Import required AWS modules
    $requiredModules = @('AWS.Tools.Common', 'AWS.Tools.S3', 'AWS.Tools.SecurityToken')
    
    foreach ($module in $requiredModules) {
        if (-not (Get-Module -Name $module -ErrorAction SilentlyContinue)) {
            Import-Module $module -ErrorAction Stop
            Write-Verbose "Imported AWS module: $module"
        }
    }
} catch {
    Write-Error "Failed to import AWS Tools for PowerShell. Please install it using: Install-Module -Name AWS.Tools.Installer -Force -Scope CurrentUser"
    Write-Error "Error details: $_"
    exit 1
}

# Function to test AWS credentials
function Test-AWSCredentials {
    try {
        $caller = Get-STSCallerIdentity -ErrorAction Stop
        return $caller.Arn
    } catch {
        return "Error: $($_.Exception.Message)"
    }
}

# Function to format size in human-readable format
function Format-Size {
    param([double]$bytes)
    if ($bytes -eq 0) { return "0 KB" }
    if ($bytes -ge 1TB) {
        return "{0:N2} TB" -f ($bytes/1TB)
    } elseif ($bytes -ge 1GB) {
        return "{0:N2} GB" -f ($bytes/1GB)
    } elseif ($bytes -ge 1MB) {
        return "{0:N2} MB" -f ($bytes/1MB)
    } else {
        return "{0:N2} KB" -f ($bytes/1KB)
    }
}

# Function to get AWS regions
function Get-AWSRegions {
    param(
        [switch]$AllRegions = $false
    )
    
    try {
        if ($AllRegions) {
            # Get all available AWS regions
            return (Get-AWSRegion).Region | Sort-Object
        } else {
            # Default to US regions
            return @(
                'us-east-1',  # US East (N. Virginia)
                'us-east-2',  # US East (Ohio)
                'us-west-1',  # US West (N. California)
                'us-west-2'   # US West (Oregon)
            ) | Sort-Object
        }
    } catch {
        Write-Warning "Error getting AWS regions: $($_.Exception.Message)"
        Write-Warning "Defaulting to us-east-1"
        return @('us-east-1')
    }
}

# Function to test bucket permissions
function Test-S3BucketPermission {
    param(
        [string]$BucketName,
        [string]$Region
    )
    
    $permissions = @{
        ListObjects = $false
        ListBucket = $false
        Read = $false
    }
    
    try {
        # Test ListObjects permission
        $null = Get-S3Object -BucketName $BucketName -Region $Region -MaxItems 1 -ErrorAction Stop
        $permissions.ListObjects = $true
        $permissions.ListBucket = $true
        $permissions.Read = $true
    } catch [Amazon.S3.AmazonS3Exception] {
        if ($_.Exception.ErrorCode -eq 'AccessDenied') {
            $permissions.ListObjects = $false
        }
    } catch {
        Write-Debug "Error testing ListObjects on $BucketName : $_"
    }
    
    return $permissions
}

# Define parameters with proper syntax
param(
    [string]$ProfileName = "default",
    [switch]$SkipLargeBuckets,
    [switch]$AllRegions
)

# Set default values
if (-not $PSBoundParameters.ContainsKey('AllRegions')) { $AllRegions = $false }
if (-not $PSBoundParameters.ContainsKey('SkipLargeBuckets')) { $SkipLargeBuckets = $false }
if ([string]::IsNullOrEmpty($ProfileName)) { $ProfileName = "default" }

# Initialize global variables
$allResults = @()
$global:regionStats = @{}

# Initialize AWS configuration
Write-Host "Initializing AWS configuration..."

# Get AWS region from environment or config
$region = $env:AWS_DEFAULT_REGION
if (-not $region) {
    $region = aws configure get region --profile default 2>$null
    if (-not $region) {
        $region = 'us-east-1'  # Default to us-east-1 if not set
    }
}

# Set environment variable for AWS CLI
$env:AWS_DEFAULT_REGION = $region
Write-Host "Using AWS region: $region"

# Test AWS credentials
try {
    $caller = aws sts get-caller-identity --output json 2>&1 | ConvertFrom-Json
    if (-not $caller.Arn) { throw "Failed to get caller identity" }
    Write-Host "Successfully authenticated as: $($caller.Arn)"
} catch {
    Write-Error "Failed to authenticate with AWS. Please check your credentials."
    Write-Error "Error: $($_.Exception.Message)"
    Write-Host ""
    Write-Host "To configure AWS credentials, you can run:"
    Write-Host "1. aws configure"
    Write-Host "   or"
    Write-Host "2. Set environment variables: AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, and optionally AWS_DEFAULT_REGION"
    exit 1
}
} catch {
    Write-Error "Failed to initialize AWS: $_"
    Write-Error "Please ensure you have valid AWS credentials configured in ~/.aws/credentials"
    exit 1
}

# Get regions to process
$Regions = if ($AllRegions) { 
    Get-AWSRegions -AllRegions 
} else { 
    Get-AWSRegions 
}

# Process each region
foreach ($Region in $Regions) {
    Write-Host "`n=== Processing region: $Region ===" -ForegroundColor Cyan
    
    try {
        Write-Host "`nFetching buckets for region: $Region"
        
        # Get all S3 buckets
        try {
            Write-Host "Retrieving S3 buckets..."
            
            # Get all buckets using AWS CLI
            $bucketsJson = aws s3api list-buckets --query "Buckets[*].{Name:Name,CreationDate:CreationDate}" --output json 2>&1
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to list S3 buckets: $bucketsJson"
            try {
                $location = Get-S3BucketLocation -BucketName $bucket.BucketName -ErrorAction Stop
                $bucketRegion = if ([string]::IsNullOrEmpty($location.Value)) { 'us-east-1' } else { $location.Value }
                
                if ($AllRegions -or $bucketRegion -eq $Region) {
                    $bucketsInRegion += $bucket
                }
            } catch {
                Write-Warning "  Could not determine region for bucket $($bucket.BucketName): $_"
                # Add to list anyway if we're processing all regions
                if ($AllRegions) { $bucketsInRegion += $bucket }
            }
        }
        
        Write-Progress -Activity "Checking bucket regions" -Completed
        Write-Host "Found $($bucketsInRegion.Count) buckets in region $Region"
        
        if ($bucketsInRegion.Count -eq 0) {
            Write-Host "No buckets found in region $Region" -ForegroundColor Yellow
            continue
        }
        
        # Process each bucket in the region
        $bucketNum = 0
        foreach ($bucket in $bucketsInRegion) {
            $bucketNum++
            $bucketName = $bucket.BucketName
            
            Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] [$bucketNum/$($bucketsInRegion.Count)] Analyzing bucket: $bucketName" -ForegroundColor Green
            
            try {
                # Test bucket permissions first
                $permissions = Test-S3BucketPermission -BucketName $bucketName -Region $Region
                
                if (-not $permissions.ListObjects) {
                    Write-Warning "  Insufficient permissions to list objects in bucket $bucketName"
                    Write-Host "  Permissions: ListObjects=$($permissions.ListObjects), ListBucket=$($permissions.ListBucket), Read=$($permissions.Read)" -ForegroundColor Yellow
                    continue
                }
                
                # Initialize variables for object listing
                $objectCount = 0
                $totalSize = 0
                $nextToken = $null
                $isTruncated = $true
                $objects = @()
                $maxRetries = 3
                $retryCount = 0
                $startTime = Get-Date
                $timeoutMinutes = 5
                
                Write-Host "  Starting object enumeration..."
                
                # Create S3 client with explicit timeout
                $s3Config = [Amazon.S3.AmazonS3Config]::new()
                $s3Config.Timeout = [System.TimeSpan]::FromSeconds(30)
                $s3Client = [Amazon.S3.AmazonS3Client]::new($Region, $s3Config)
                
                try {
                    while ($isTruncated) {
                        $retryCount = 0
                        $batchSuccess = $false
                        
                        # Check for overall timeout
                        if ((Get-Date) - $startTime -gt [System.TimeSpan]::FromMinutes($timeoutMinutes)) {
                            Write-Warning "  Object listing timed out after $timeoutMinutes minutes"
                            break
                        }
                        
                        # Check if we've reached the limit for large buckets
                        if ($SkipLargeBuckets -and $objectCount -ge 1000) {
                            Write-Host "  Reached 1000 objects (skipping remaining objects)" -ForegroundColor Yellow
                            break
                        }
                        
                        # Retry logic for the current batch
                        while (-not $batchSuccess -and $retryCount -lt $maxRetries) {
                            try {
                                $request = [Amazon.S3.Model.ListObjectsV2Request]::new()
                                $request.BucketName = $bucketName
                                $request.MaxKeys = 1000
                                if ($nextToken) {
                                    $request.ContinuationToken = $nextToken
                                }
                                
                                # Get objects with timeout
                                $response = $s3Client.ListObjectsV2Async($request).GetAwaiter().GetResult()
                                
                                if ($response) {
                                    $isTruncated = $response.IsTruncated
                                    $nextToken = if ($isTruncated) { $response.NextContinuationToken } else { $null }
                                    
                                    if ($response.KeyCount -gt 0) {
                                        $batchCount = $response.KeyCount
                                        $batchSize = ($response.S3Objects | Measure-Object -Property Size -Sum).Sum
                                        
                                        $objectCount += $batchCount
                                        $totalSize += $batchSize
                                        
                                        if ($SkipLargeBuckets) {
                                            $objects += $response.S3Objects | Select-Object -First (1000 - $objects.Count)
                                        } else {
                                            $objects += $response.S3Objects
                                        }
                                        
                                        $sizeFormatted = Format-Size $totalSize
                                        Write-Host "  Found $objectCount objects (Total: $sizeFormatted) - Batch: $batchCount objects"
                                        
                                        # Reset retry counter on success
                                        $batchSuccess = $true
                                        $retryCount = 0
                                    } else {
                                        Write-Verbose "  No objects in batch"
                                        $batchSuccess = $true
                                    }
                                } else {
                                    throw "No response received from S3"
                                }
                                
                            } catch [System.Exception] {
                                $retryCount++
                                if ($retryCount -ge $maxRetries) {
                                    Write-Warning "  Failed to list objects after $maxRetries attempts: $_"
                                    $isTruncated = $false
                                    break
                                }
                                Write-Warning "  Error listing objects (attempt $retryCount/$maxRetries): $_"
                                Start-Sleep -Seconds ([math]::Min([math]::Pow(2, $retryCount), 10))  # Cap backoff at 10 seconds
                            }
                        }
                        
                        if (-not $batchSuccess) {
                            Write-Error "  Failed to list objects after $maxRetries attempts. Moving to next bucket."
                            $isTruncated = $false
                            break
                        }
                    }
                } finally {
                    # Clean up the S3 client
                    if ($s3Client -ne $null) {
                        $s3Client.Dispose()
                    }
                }
                
                # Get storage class distribution
                $storageClasses = $objects | Group-Object StorageClass | 
                    Select-Object @{Name='StorageClass';Expression={$_.Name}}, 
                                @{Name='Count';Expression={$_.Count}}, 
                                @{Name='Size';Expression={($_.Group | Measure-Object -Property Size -Sum).Sum}}
                
                # Add to results
                $result = [PSCustomObject]@{
                    BucketName = $bucketName
                    Region = $Region
                    ObjectCount = $objectCount
                    TotalSize = $totalSize
                    TotalSizeFormatted = Format-Size $totalSize
                    StorageClasses = ($storageClasses | ForEach-Object { 
                        "$($_.StorageClass): $($_.Count) obj ($(Format-Size $_.Size))" 
                    }) -join ' | '
                    LastModified = if ($objects) { $objects | Sort-Object LastModified -Descending | Select-Object -First 1 -ExpandProperty LastModified } else { $null }
                    HasMoreObjects = $isTruncated -and $SkipLargeBuckets
                }
                
                $allResults += $result
                
                # Update region stats
                if (-not $global:regionStats.ContainsKey($Region)) {
                    $global:regionStats[$Region] = @{
                        Buckets = 0
                        Objects = 0
                        Size = 0
                    }
                }
                $global:regionStats[$Region].Buckets++
                $global:regionStats[$Region].Objects += $objectCount
                $global:regionStats[$Region].Size += $totalSize
                
                # Output bucket summary
                Write-Host "  Bucket Summary:" -ForegroundColor Cyan
                Write-Host "  - Objects: $objectCount"
                Write-Host "  - Total Size: $(Format-Size $totalSize)"
                if ($result.HasMoreObjects) {
                    Write-Host "  - Note: More objects exist in this bucket (limited by -SkipLargeBuckets)" -ForegroundColor Yellow
                }
                if ($storageClasses) {
                    Write-Host "  - Storage Classes:"
                    foreach ($sc in $storageClasses) {
                        Write-Host "    - $($sc.StorageClass): $($sc.Count) objects ($(Format-Size $sc.Size))"
                    }
                }
                
            } catch {
                Write-Error "  Error processing bucket $bucketName : $_"
                continue
            }
        }
        
    } catch {
        Write-Error "Error processing region $Region : $_"
        continue
    }
}

# Output summary report
Write-Host "`n=== SUMMARY REPORT ===" -ForegroundColor Cyan
Write-Host "Total Buckets: $($allResults.Count)"
Write-Host "Total Objects: $(($allResults | Measure-Object -Property ObjectCount -Sum).Sum)"
Write-Host "Total Storage: $(Format-Size (($allResults | Measure-Object -Property TotalSize -Sum).Sum))"

# Output by region
if ($global:regionStats.Count -gt 0) {
    Write-Host "`n=== STORAGE BY REGION ===" -ForegroundColor Cyan
    foreach ($region in ($global:regionStats.Keys | Sort-Object)) {
        $stats = $global:regionStats[$region]
        Write-Host "`nREGION: $region"
        Write-Host "- Buckets: $($stats.Buckets)"
        Write-Host "- Objects: $($stats.Objects)"
        Write-Host "- Total Size: $(Format-Size $stats.Size)"
    }
}

# Output to CSV
$csvPath = Join-Path -Path $PSScriptRoot -ChildPath "s3-bucket-report_$(Get-Date -Format 'yyyyMMdd-HHmmss').csv"
try {
    $allResults | Select-Object BucketName, Region, ObjectCount, @{Name='TotalSizeBytes';Expression={$_.TotalSize}}, TotalSizeFormatted, StorageClasses, LastModified, HasMoreObjects |
        Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8 -Force
    Write-Host "`nReport saved to: $csvPath" -ForegroundColor Green
} catch {
    Write-Error "Failed to save report: $_"
}

Write-Host "`nScript completed at $(Get-Date)" -ForegroundColor Cyan
