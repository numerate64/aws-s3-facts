# Simple S3 Bucket Report using AWS CLI
# This script provides a summary of S3 buckets and their contents

param(
    [switch]$SkipLargeBuckets = $false,
    [string]$ProfileName = "default",
    [string]$Region = "us-east-1"
)

# Set error action preference
$ErrorActionPreference = "Stop"

# Function to format size in human-readable format
function Format-Size {
    param([long]$size)
    
    $suffix = 'B', 'KB', 'MB', 'GB', 'TB', 'PB', 'EB'
    $index = 0
    
    while ($size -gt 1KB -and $index -lt ($suffix.Length - 1)) {
        $size = $size / 1KB
        $index++
    }
    
    return "{0:N2} {1}" -f $size, $suffix[$index]
}

# Function to get bucket region
function Get-BucketRegion {
    param([string]$bucketName)
    
    try {
        $location = aws s3api get-bucket-location --bucket $bucketName --query "LocationConstraint" --output text 2>$null
        if ([string]::IsNullOrEmpty($location) -or $location -eq 'None') {
            return 'us-east-1'
        }
        return $location
    } catch {
        Write-Warning "Failed to get region for bucket ${bucketName}: $_"
        return $null
    }
}

# Function to get bucket objects
function Get-BucketObjects {
    param(
        [string]$bucketName,
        [string]$region,
        [switch]$skipLarge = $false
    )
    
    $objects = @()
    $continuationToken = $null
    $totalSize = 0
    $objectCount = 0
    $maxObjects = 1000
    
    # Initialize storage class tracking
    $storageClasses = @{
        'STANDARD' = @{Count=0; Size=0}
        'STANDARD_IA' = @{Count=0; Size=0}
        'INTELLIGENT_TIERING' = @{Count=0; Size=0}
        'ONEZONE_IA' = @{Count=0; Size=0}
        'GLACIER' = @{Count=0; Size=0}
        'DEEP_ARCHIVE' = @{Count=0; Size=0}
        'GLACIER_IR' = @{Count=0; Size=0}
        'OUTPOSTS' = @{Count=0; Size=0}
        'SNOW' = @{Count=0; Size=0}
        'EXPRESS_ONEZONE' = @{Count=0; Size=0}
        'UNKNOWN' = @{Count=0; Size=0}
    }
    
    try {
        do {
            # Find AWS CLI executable
            $awsExe = (Get-Command aws -ErrorAction SilentlyContinue).Source
            if (-not $awsExe) {
                $awsExe = "$env:ProgramFiles\Amazon\AWSCLIV2\aws.exe"
                if (-not (Test-Path $awsExe)) {
                    $awsExe = "$env:ProgramFiles\Amazon\AWSCLIV2\bin\aws.cmd"
                }
            }
            
            if (-not (Test-Path $awsExe)) {
                throw "AWS CLI not found. Please install AWS CLI v2 and ensure it's in your PATH."
            }
            
            # Build the AWS CLI command to include storage class
            $awsArgs = @(
                "s3api", "list-objects-v2",
                "--bucket", "$bucketName",
                "--region", "$region",
                "--output", "json"
            )
            
            # Add pagination token if available
            if ($continuationToken) {
                $awsArgs += "--starting-token"
                $awsArgs += $continuationToken
            }
            
            # Execute the command and handle the output
            $result = & $awsExe $awsArgs 2>$null | ConvertFrom-Json
            
            # Check if we got any objects
            if ($result.Contents) {
                $batchCount = $result.Contents.Count
                $batchSize = ($result.Contents | Measure-Object -Property Size -Sum).Sum
                
                $objects += $result.Contents
                $totalSize += $batchSize
                $objectCount += $batchCount
                
                # Track storage classes
                foreach ($obj in $result.Contents) {
                    $storageClass = if ($obj.StorageClass) { $obj.StorageClass } else { 'STANDARD' }
                    if (-not $storageClasses.ContainsKey($storageClass)) {
                        $storageClass = 'UNKNOWN'
                    }
                    $storageClasses[$storageClass].Count++
                    $storageClasses[$storageClass].Size += $obj.Size
                }
                
                Write-Host "  Found $batchCount objects in batch (Total: $objectCount objects, $(Format-Size $totalSize))"
                
                # Check if we should stop early
                if ($skipLarge -and $objectCount -ge $maxObjects) {
                    Write-Host "  Reached $maxObjects objects, skipping remaining..." -ForegroundColor Yellow
                    break
                }
            }
            
            # Check if there are more objects to fetch
            if ($result.IsTruncated -and $result.NextToken) {
                $continuationToken = $result.NextToken
            } else {
                $continuationToken = $null
            }
            
        } while ($continuationToken)
        
    } catch {
        Write-Warning "  Error listing objects in $bucketName : $_"
    }
    
    # Convert storage classes to a cleaner format
    $storageClassInfo = $storageClasses.GetEnumerator() | Where-Object { $_.Value.Count -gt 0 } | ForEach-Object {
        [PSCustomObject]@{
            StorageClass = $_.Key
            ObjectCount = $_.Value.Count
            TotalSize = $_.Value.Size
            FormattedSize = Format-Size $_.Value.Size
        }
    }
    
    return @{
        Objects = $objects
        TotalSize = $totalSize
        ObjectCount = $objectCount
        StorageClasses = $storageClassInfo
    }
}

# Main script
Write-Host "=== S3 Bucket Report ==="
Write-Host "Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Host ""

# Set AWS profile if specified
if ($ProfileName -ne "default") {
    $env:AWS_PROFILE = $ProfileName
}

# Set AWS region
$env:AWS_DEFAULT_REGION = $Region

# Test AWS credentials
try {
    $caller = aws sts get-caller-identity --output json 2>&1 | ConvertFrom-Json
    if (-not $caller.Arn) { throw "Failed to get caller identity" }
    Write-Host "Authenticated as: $($caller.Arn)"
} catch {
    Write-Error "Failed to authenticate with AWS. Please check your credentials."
    Write-Error "Error: $_"
    Write-Host ""
    Write-Host "To configure AWS credentials, you can run:"
    Write-Host "1. aws configure"
    Write-Host "   or"
    Write-Host "2. Set environment variables: AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, and optionally AWS_DEFAULT_REGION"
    exit 1
}

# Get all buckets
Write-Host "`nFetching S3 buckets..."
try {
    $buckets = aws s3api list-buckets --query "Buckets[*].{Name:Name,CreationDate:CreationDate}" --output json 2>&1 | ConvertFrom-Json
    if (-not $buckets) { throw "No buckets found or access denied" }
} catch {
    Write-Error "Failed to list S3 buckets: $_"
    exit 1
}

Write-Host "Found $($buckets.Count) buckets"

# Process each bucket
$report = @()
$totalObjects = 0
$totalSize = 0

foreach ($bucket in $buckets) {
    $bucketName = $bucket.Name
    
    # Process all buckets including CloudTrail
    Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Processing bucket: $bucketName"
    
    Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Processing bucket: $bucketName"
    
    try {
        # Get bucket region
        $bucketRegion = Get-BucketRegion -bucketName $bucketName
        if (-not $bucketRegion) {
            Write-Warning "  Could not determine bucket region, skipping..."
            continue
        }
        
        # Get bucket objects
        Write-Host "  Getting objects from $bucketRegion..."
        $objects = Get-BucketObjects -bucketName $bucketName -region $bucketRegion -skipLarge:$SkipLargeBuckets
        
        # Add to totals
        $totalObjects += $objects.ObjectCount
        $totalSize += $objects.TotalSize
        
        # Add to report
        $report += [PSCustomObject]@{
            BucketName = $bucketName
            Region = $bucketRegion
            ObjectCount = $objects.ObjectCount
            TotalSize = Format-Size $objects.TotalSize
            RawSize = $objects.TotalSize
            CreationDate = $bucket.CreationDate
            StorageClasses = $objects.StorageClasses
        }  
        Write-Host "  - Objects: $($objects.ObjectCount)"
        Write-Host "  - Total Size: $(Format-Size $objects.TotalSize)"
        
    } catch {
        Write-Warning "  Error processing bucket $bucketName : $_"
    }
}

# Generate report
Write-Host "`n=== Report Summary ==="
Write-Host "Total Buckets Processed: $($report.Count)"
Write-Host "Total Objects: $totalObjects"
Write-Host "Total Storage: $(Format-Size $totalSize)"

# Group by region
$byRegion = $report | Group-Object Region | Sort-Object Name | ForEach-Object {
    $size = ($_.Group | Measure-Object -Property RawSize -Sum).Sum
    [PSCustomObject]@{
        Region = $_.Name
        BucketCount = $_.Count
        ObjectCount = ($_.Group | Measure-Object -Property ObjectCount -Sum).Sum
        TotalSize = Format-Size $size
    }
}

# Calculate storage class summary across all buckets
$allStorageClasses = @{}
foreach ($bucket in $report) {
    foreach ($sc in $bucket.StorageClasses) {
        if (-not $allStorageClasses.ContainsKey($sc.StorageClass)) {
            $allStorageClasses[$sc.StorageClass] = @{Count=0; Size=0}
        }
        $allStorageClasses[$sc.StorageClass].Count += $sc.ObjectCount
        $allStorageClasses[$sc.StorageClass].Size += $sc.TotalSize
    }
}

# Convert to sorted array
$storageClassSummary = $allStorageClasses.GetEnumerator() | ForEach-Object {
    [PSCustomObject]@{
        StorageClass = $_.Key
        ObjectCount = $_.Value.Count
        TotalSize = Format-Size $_.Value.Size
        RawSize = $_.Value.Size
    }
} | Sort-Object -Property RawSize -Descending

Write-Host "`n=== By Region ==="
$byRegion | Format-Table -AutoSize

# Show storage class summary
Write-Host "`n=== Storage Class Summary ==="
$storageClassSummary | Format-Table -Property StorageClass, ObjectCount, @{Name="TotalSize";Expression={$_.TotalSize};Align="Right"} -AutoSize

# Save detailed report to CSV
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$csvPath = "s3-bucket-report-$timestamp.csv"

# Prepare CSV data with all storage classes as columns
# First, get all possible storage classes across all buckets
$allStorageClassNames = $report.StorageClasses | ForEach-Object { $_.StorageClass } | Sort-Object -Unique

# Create CSV data with consistent columns
$csvData = foreach ($item in $report) {
    # Format creation date
    $creationDate = if ($item.CreationDate) { 
        (Get-Date $item.CreationDate).ToString('yyyy-MM-dd HH:mm:ss "UTC"zzz') 
    } else { 
        'N/A' 
    }
    
    # Create base properties
    $csvItem = [PSCustomObject]@{
        'Bucket Name'    = $item.BucketName
        'Region'         = $item.Region
        'Total Objects'  = $item.ObjectCount
        'Total Size'     = $item.TotalSize
        'Creation Date'  = $creationDate
    }
    
    # Initialize all storage class columns with zeros
    foreach ($sc in $allStorageClassNames) {
        $csvItem | Add-Member -MemberType NoteProperty -Name "$sc Objects" -Value 0
        $csvItem | Add-Member -MemberType NoteProperty -Name "$sc Size" -Value '0 B'
    }
    
    # Fill in actual values for this bucket's storage classes
    foreach ($sc in $item.StorageClasses) {
        $scName = $sc.StorageClass
        $csvItem."$scName Objects" = $sc.ObjectCount
        $csvItem."$scName Size" = $sc.FormattedSize
    }
    
    $csvItem
}

# Reorder columns for better readability
$columnOrder = @('Bucket Name', 'Region', 'Creation Date', 'Total Objects', 'Total Size')
$storageClassColumns = $allStorageClassNames | ForEach-Object { 
    $sc = $_
    @("$sc Objects", "$sc Size")
} | Select-Object -Unique

$columnOrder += $storageClassColumns

# Export to CSV with ordered columns
$csvData | Select-Object $columnOrder | 
    Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8

Write-Host "`nReport saved to: $csvPath"
