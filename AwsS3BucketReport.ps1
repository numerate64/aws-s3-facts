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

$allStorageClasses = @{}
foreach ($bucket in $buckets) {
    $bucketName = $bucket.BucketName
    Write-Host "Processing bucket: $bucketName" -ForegroundColor Yellow
    $objs = Get-S3Object -BucketName $bucketName -Region $Region -Credential $creds
    Write-Host "  Object count: $($objs.Count)" -ForegroundColor Green
    $objs | Select-Object -First 3 | ForEach-Object {
        Write-Host ("    Key: {0}, Size: {1} bytes, StorageClass: {2}" -f $_.Key, $_.Size, $_.StorageClass)
    }
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
    }
    # Debug: print all storage classes found in this bucket
    Write-Host ("  Storage classes found in bucket: {0}" -f ($storageClassesInBucket.Keys -join ", ")) -ForegroundColor Cyan
    foreach ($class in $storageClassesInBucket.Keys) {
        if ($class -ne "STANDARD") {
            Write-Host ("    Example object in {0}: {1}" -f $class, ($objs | Where-Object { ($_.StorageClass -eq $class) } | Select-Object -First 1 -ExpandProperty Key)) -ForegroundColor Magenta
        }
    }
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
Write-Host "CSV output saved to: $csvPath" -ForegroundColor Cyan

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
Write-Host ("Summary: {0} buckets, {1} objects, {2}" -f $totalBuckets, $totalObjects, (Format-Size $totalStorage)) -ForegroundColor Magenta
