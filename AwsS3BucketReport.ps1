# Requires AWS Tools for PowerShell
# This script will auto-install the required module if missing.

param(
    [string]$AccessKey = $null,
    [string]$SecretKey = $null,
    [string]$Region = "us-east-1"
)

# Ensure AWS.Tools.S3 is installed
if (-not (Get-Module -ListAvailable -Name AWS.Tools.S3)) {
    Write-Host "AWS.Tools.S3 module not found. Installing..." -ForegroundColor Yellow
    Install-Module -Name AWS.Tools.S3 -Scope CurrentUser -Force
}

# Import AWS.Tools.S3 and suppress warnings about multiple AWS modules
Import-Module AWS.Tools.S3 -ErrorAction SilentlyContinue *>$null

# Prompt for keys if not provided
if (-not $AccessKey) {
    $AccessKey = Read-Host -AsSecureString "Enter your AWS Access Key ID" | ConvertFrom-SecureString -AsPlainText
}
if (-not $SecretKey) {
    $SecretKey = Read-Host -AsSecureString "Enter your AWS Secret Access Key" | ConvertFrom-SecureString -AsPlainText
}

$creds = [Amazon.Runtime.BasicAWSCredentials]::new($AccessKey, $SecretKey)

# Get all S3 buckets using explicit credentials
$buckets = Get-S3Bucket -Region $Region -Credential $creds

# Initialize storage tracking
$allStorageClasses = @{}
$totalStorageByClass = @{}
$totalObjectsByClass = @{}
# Process each bucket with progress
$bucketCount = $buckets.Count
$current = 0

foreach ($bucket in $buckets) {
    $current++
    $bucketName = $bucket.BucketName
    
    # Show progress
    $progressStatus = "Processing bucket $current of $bucketCount"
    $progressParams = @{
        Activity = 'Analyzing S3 Buckets'
        Status = $progressStatus
        PercentComplete = ($current / $bucketCount * 100)
        CurrentOperation = "Bucket: $bucketName"
    }
    Write-Progress @progressParams
    
    $objs = Get-S3Object -BucketName $bucketName -Region $Region -Credential $creds
    
    # Update progress with object count
    $progressParams.CurrentOperation = "Found $($objs.Count) objects"
    Write-Progress @progressParams
    
    # Summarize by storage class
    $summary = @{}
    $storageClassesInBucket = @{}
    foreach ($obj in $objs) {
        $class = if ($obj.StorageClass) { $obj.StorageClass } else { "STANDARD" }
        if (-not $summary.ContainsKey($class)) { $summary[$class] = 0 }
        $summary[$class] += $obj.Size
        if (-not $storageClassesInBucket.ContainsKey($class)) { $storageClassesInBucket[$class] = 0 }
        $storageClassesInBucket[$class]++
        $allStorageClasses[$class] = $true
            
        # Initialize class tracking if needed
        if (-not $totalStorageByClass.ContainsKey($class)) {
            $totalStorageByClass[$class] = 0
            $totalObjectsByClass[$class] = 0
        }
        
        # Update class totals
        $totalStorageByClass[$class] += $obj.Size
        $totalObjectsByClass[$class]++
    }
    # Store storage classes for this bucket
    $bucket.PSObject.Properties.Add((New-Object PSNoteProperty('StorageSummary', $summary)))
}

function Format-Size {
    param([double]$bytes)
    if ($bytes -ge 1GB) {
        return "{0} GB" -f ([math]::Round($bytes/1GB,2))
    } elseif ($bytes -ge 1MB) {
        return "{0} MB" -f ([math]::Round($bytes/1MB,2))
    } else {
        return "{0} KB" -f ([math]::Round($bytes/1KB,2))
    }
}

# Prepare results with all storage classes as columns
$results = @()
$storageClassList = $allStorageClasses.Keys
foreach ($bucket in $buckets) {
    $row = [ordered]@{ BucketName = $bucket.BucketName }
    # Add object count per bucket
    $objs = Get-S3Object -BucketName $bucket.BucketName -Region $Region -Credential $creds
    $row['ObjectCount'] = $objs.Count
    # Add per-tier (storage class) object count
    foreach ($class in $storageClassList) {
        $sizeValue = if ($bucket.StorageSummary.ContainsKey($class)) { $bucket.StorageSummary[$class] } else { 0 }
        $row[$class] = Format-Size $sizeValue
        $objCount = ($objs | Where-Object { ($_.StorageClass -eq $class) -or (-not $_.StorageClass -and $class -eq 'STANDARD') }).Count
        $row["${class}_ObjectCount"] = $objCount
    }
    $results += New-Object PSObject -Property $row
}

# Output results as a table
$results | Format-Table -AutoSize

# Output results as CSV
$csvPath = Join-Path -Path (Get-Location) -ChildPath "s3-bucket-summary.csv"
$results | Export-Csv -Path $csvPath -NoTypeInformation -Force
Write-Host "CSV output saved to: $csvPath"

# Output summary
$totalBuckets = $results.Count
$totalStorage = 0
$totalObjects = 0
foreach ($bucket in $buckets) {
    $objs = Get-S3Object -BucketName $bucket.BucketName -Region $Region -Credential $creds
    $totalObjects += $objs.Count
}
foreach ($bucket in $buckets) {
    foreach ($class in $storageClassList) {
        if ($bucket.StorageSummary.ContainsKey($class)) {
            $totalStorage += $bucket.StorageSummary[$class]
        }
    }
}
# Clear progress
Write-Progress -Activity "Analysis Complete" -Completed

# Prepare and display summary
Write-Host "`nSummary:"
Write-Host ("- {0} buckets" -f $totalBuckets)
Write-Host ("- {0} objects total" -f $totalObjects)
Write-Host ("- {0} total storage" -f (Format-Size $totalStorage))

# Add storage by class breakdown
Write-Host "`nStorage by Class:"
$totalStorageByClass.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object {
    $class = $_.Key
    $storage = $_.Value
    $objects = $totalObjectsByClass[$class]
    Write-Host ("- {0,-15}: {1,10} storage in {2,6} objects" -f 
        $class, 
        (Format-Size $storage),
        $objects)
}
