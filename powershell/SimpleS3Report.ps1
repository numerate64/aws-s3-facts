<#
.SYNOPSIS
Counts S3 objects and sums exact capacity by S3 storage class.

.DESCRIPTION
Uses one automatically paginated AWS CLI process per bucket and scans buckets
in parallel on PowerShell 7. PowerShell 5.1 is supported with sequential scans.
Object metadata is aggregated as it arrives and is never retained in memory.
#>

[CmdletBinding()]
param(
    [string]$ProfileName,
    [ValidateRange(1, 64)]
    [int]$Workers = 8,
    [string]$OutputPath = "s3-bucket-report-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv",
    [switch]$RequesterPays
)

$ErrorActionPreference = 'Stop'

function Format-Size {
    param([long]$Bytes)

    $value = [double]$Bytes
    foreach ($unit in @('B', 'KiB', 'MiB', 'GiB', 'TiB', 'PiB')) {
        if ($value -lt 1024 -or $unit -eq 'PiB') {
            if ($unit -eq 'B') { return '{0:N0} {1}' -f $value, $unit }
            return '{0:N2} {1}' -f $value, $unit
        }
        $value /= 1024
    }
}

function Get-AwsBaseArguments {
    param([string]$Profile)

    $arguments = [System.Collections.Generic.List[string]]::new()
    if (-not [string]::IsNullOrWhiteSpace($Profile)) {
        $arguments.Add('--profile')
        $arguments.Add($Profile)
    }
    $arguments.Add('--no-cli-pager')
    return $arguments.ToArray()
}

$awsCommand = Get-Command aws -ErrorAction SilentlyContinue
if (-not $awsCommand) {
    throw 'AWS CLI v2 was not found in PATH.'
}

$awsExecutable = $awsCommand.Source
$baseArguments = Get-AwsBaseArguments -Profile $ProfileName
$useRequesterPays = [bool]$RequesterPays

try {
    $identityJson = & $awsExecutable @baseArguments sts get-caller-identity --output json
    if ($LASTEXITCODE -ne 0) { throw 'AWS authentication failed.' }
    $identity = $identityJson | ConvertFrom-Json

    $bucketJson = & $awsExecutable @baseArguments s3api list-buckets `
        --query 'Buckets[].{Name:Name,CreationDate:CreationDate}' --output json
    if ($LASTEXITCODE -ne 0) { throw 'Unable to list S3 buckets.' }
    $buckets = @($bucketJson | ConvertFrom-Json)
}
catch {
    throw "Unable to initialize AWS access: $($_.Exception.Message)"
}

$scanBucket = {
    param(
        $Bucket,
        [string]$AwsExecutable,
        [string[]]$BaseArguments,
        [bool]$UseRequesterPays
    )

    $started = [System.Diagnostics.Stopwatch]::StartNew()
    $bucketName = [string]$Bucket.Name
    $region = ''
    $objectCount = [long]0
    $totalBytes = [long]0
    $tiers = @{}
    $errorMessage = ''

    try {
        $location = & $AwsExecutable @BaseArguments s3api get-bucket-location `
            --bucket $bucketName --query LocationConstraint --output text 2>&1
        if ($LASTEXITCODE -ne 0) { throw ($location -join [Environment]::NewLine) }

        $region = ([string]$location).Trim()
        if ([string]::IsNullOrWhiteSpace($region) -or $region -eq 'None') {
            $region = 'us-east-1'
        }
        elseif ($region -eq 'EU') {
            $region = 'eu-west-1'
        }

        $listArguments = [System.Collections.Generic.List[string]]::new()
        foreach ($argument in $BaseArguments) { $listArguments.Add($argument) }
        $listArguments.Add('s3api')
        $listArguments.Add('list-objects-v2')
        $listArguments.Add('--bucket')
        $listArguments.Add($bucketName)
        $listArguments.Add('--region')
        $listArguments.Add($region)
        $listArguments.Add('--page-size')
        $listArguments.Add('1000')
        $listArguments.Add('--query')
        $listArguments.Add('Contents[].[Size,StorageClass]')
        $listArguments.Add('--output')
        $listArguments.Add('text')
        if ($UseRequesterPays) {
            $listArguments.Add('--request-payer')
            $listArguments.Add('requester')
        }

        $listArgumentArray = $listArguments.ToArray()
        & $AwsExecutable @listArgumentArray 2>&1 | ForEach-Object {
            $line = [string]$_
            $fields = $line -split "`t", 2
            $size = [long]0
            if ($fields.Count -eq 2 -and [long]::TryParse($fields[0], [ref]$size)) {
                $storageClass = $fields[1].Trim().ToUpperInvariant()
                if ([string]::IsNullOrWhiteSpace($storageClass) -or $storageClass -eq 'NONE') {
                    $storageClass = 'STANDARD'
                }

                if (-not $tiers.ContainsKey($storageClass)) {
                    $tiers[$storageClass] = @{
                        ObjectCount = [long]0
                        SizeBytes = [long]0
                    }
                }

                $objectCount++
                $totalBytes += $size
                $tiers[$storageClass].ObjectCount++
                $tiers[$storageClass].SizeBytes += $size
            }
        }

        if ($LASTEXITCODE -ne 0) {
            throw "AWS CLI list-objects-v2 exited with code $LASTEXITCODE."
        }
    }
    catch {
        $errorMessage = $_.Exception.Message
    }
    finally {
        $started.Stop()
    }

    [PSCustomObject]@{
        BucketName = $bucketName
        Region = $region
        CreationDate = $Bucket.CreationDate
        ObjectCount = $objectCount
        SizeBytes = $totalBytes
        Tiers = $tiers
        Error = $errorMessage
        ElapsedSeconds = $started.Elapsed.TotalSeconds
    }
}
$scanBucketText = $scanBucket.ToString()

Write-Host "AWS account: $($identity.Account)"
Write-Host "Found $($buckets.Count) buckets; scanning with $Workers worker(s)..."
$overallTimer = [System.Diagnostics.Stopwatch]::StartNew()

if ($PSVersionTable.PSVersion.Major -ge 7 -and $Workers -gt 1) {
    $results = @(
        $buckets | ForEach-Object -Parallel {
            $worker = [scriptblock]::Create($using:scanBucketText)
            & $worker $_ $using:awsExecutable $using:baseArguments $using:useRequesterPays
        } -ThrottleLimit $Workers
    )
}
else {
    if ($Workers -gt 1) {
        Write-Warning 'PowerShell 7+ is required for parallel scans; running sequentially.'
    }
    $results = @(
        foreach ($bucket in $buckets) {
            & $scanBucket $bucket $awsExecutable $baseArguments $useRequesterPays
        }
    )
}

$overallTimer.Stop()
$results = @($results | Sort-Object BucketName)

foreach ($result in $results) {
    if ($result.Error) {
        Write-Warning "$($result.BucketName): $($result.Error)"
    }
    else {
        Write-Host (
            '{0}: {1:N0} objects, {2} in {3:N1}s' -f `
                $result.BucketName,
                $result.ObjectCount,
                (Format-Size $result.SizeBytes),
                $result.ElapsedSeconds
        )
    }
}

$tierNames = @(
    $results |
        ForEach-Object { $_.Tiers.Keys } |
        Sort-Object -Unique
)

$csvData = foreach ($result in $results) {
    $row = [ordered]@{
        'Bucket Name' = $result.BucketName
        'Region' = $result.Region
        'Creation Date' = $result.CreationDate
        'Object Count' = $result.ObjectCount
        'Total Size (Bytes)' = $result.SizeBytes
        'Total Size' = (Format-Size $result.SizeBytes)
        'Elapsed Seconds' = $result.ElapsedSeconds
        'Error' = $result.Error
    }

    foreach ($tierName in $tierNames) {
        $usage = $result.Tiers[$tierName]
        $count = if ($usage) { [long]$usage.ObjectCount } else { [long]0 }
        $bytes = if ($usage) { [long]$usage.SizeBytes } else { [long]0 }
        $row["$tierName Objects"] = $count
        $row["$tierName Size (Bytes)"] = $bytes
        $row["$tierName Size"] = (Format-Size $bytes)
    }

    [PSCustomObject]$row
}

$successfulResults = @($results | Where-Object { -not $_.Error })
$totalObjects = [long](($successfulResults | Measure-Object ObjectCount -Sum).Sum)
$totalBytes = [long](($successfulResults | Measure-Object SizeBytes -Sum).Sum)
$tierTotals = @{}

foreach ($result in $successfulResults) {
    foreach ($tierName in $result.Tiers.Keys) {
        if (-not $tierTotals.ContainsKey($tierName)) {
            $tierTotals[$tierName] = @{ ObjectCount = [long]0; SizeBytes = [long]0 }
        }
        $tierTotals[$tierName].ObjectCount += [long]$result.Tiers[$tierName].ObjectCount
        $tierTotals[$tierName].SizeBytes += [long]$result.Tiers[$tierName].SizeBytes
    }
}

$totalRow = [ordered]@{
    'Bucket Name' = '__ACCOUNT_TOTAL__'
    'Region' = ''
    'Creation Date' = ''
    'Object Count' = $totalObjects
    'Total Size (Bytes)' = $totalBytes
    'Total Size' = (Format-Size $totalBytes)
    'Elapsed Seconds' = ''
    'Error' = ''
}
foreach ($tierName in $tierNames) {
    $usage = $tierTotals[$tierName]
    $count = if ($usage) { [long]$usage.ObjectCount } else { [long]0 }
    $bytes = if ($usage) { [long]$usage.SizeBytes } else { [long]0 }
    $totalRow["$tierName Objects"] = $count
    $totalRow["$tierName Size (Bytes)"] = $bytes
    $totalRow["$tierName Size"] = (Format-Size $bytes)
}

$csvData = @($csvData) + [PSCustomObject]$totalRow
$csvData | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8

Write-Host "`n=== S3 Storage Summary ==="
Write-Host "Buckets scanned: $($successfulResults.Count)/$($results.Count)"
Write-Host ('Total objects:   {0:N0}' -f $totalObjects)
Write-Host "Total capacity:  $(Format-Size $totalBytes) ($('{0:N0}' -f $totalBytes) bytes)"
Write-Host "`nStorage class / tier:"

$tierTotals.GetEnumerator() |
    Sort-Object Name |
    ForEach-Object {
        Write-Host (
            '  {0,-24} {1,15:N0} objects  {2,14}  ({3:N0} bytes)' -f `
                $_.Name,
                $_.Value.ObjectCount,
                (Format-Size $_.Value.SizeBytes),
                $_.Value.SizeBytes
        )
    }

Write-Host "`nCSV written to $OutputPath"
Write-Host ('Completed in {0:N1}s' -f $overallTimer.Elapsed.TotalSeconds)

if (@($results | Where-Object { $_.Error }).Count -gt 0) {
    exit 1
}
