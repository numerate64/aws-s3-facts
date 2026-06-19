<#
.SYNOPSIS
Reports S3 object count and capacity by storage tier.

.DESCRIPTION
Fast mode reads precomputed daily CloudWatch metrics. Exact mode uses one
automatically paginated AWS CLI process per bucket and scans buckets in
parallel on PowerShell 7.
#>

[CmdletBinding()]
param(
    [string]$ProfileName,
    [ValidateSet('Fast', 'Exact')]
    [string]$Mode = 'Fast',
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

function Convert-StorageTypeToTier {
    param([string]$StorageType)

    switch -Regex ($StorageType) {
        '^DeepArchive' { return 'DEEP_ARCHIVE' }
        '^GlacierInstantRetrieval|^GlacierIR' { return 'GLACIER_IR' }
        '^Glacier' { return 'GLACIER' }
        '^StandardIA' { return 'STANDARD_IA' }
        '^OneZoneIA' { return 'ONEZONE_IA' }
        '^ReducedRedundancy' { return 'REDUCED_REDUNDANCY' }
        '^ExpressOneZone' { return 'EXPRESS_ONEZONE' }
        '^IntelligentTieringFA' { return 'INTELLIGENT_TIERING_FA' }
        '^IntelligentTieringIA' { return 'INTELLIGENT_TIERING_IA' }
        '^IntelligentTieringAIA' { return 'INTELLIGENT_TIERING_AIA' }
        '^IntelligentTieringAA|^IntAA' { return 'INTELLIGENT_TIERING_AA' }
        '^IntelligentTieringDAA|^IntDAA' { return 'INTELLIGENT_TIERING_DAA' }
        '^StandardStorage' { return 'STANDARD' }
        default { return $StorageType.ToUpperInvariant() }
    }
}

function Split-Array {
    param(
        [object[]]$Items,
        [int]$Size
    )

    for ($index = 0; $index -lt $Items.Count; $index += $Size) {
        $last = [Math]::Min($index + $Size - 1, $Items.Count - 1)
        ,$Items[$index..$last]
    }
}

function Get-FastCloudWatchResults {
    param(
        [object[]]$Buckets,
        [string]$AwsExecutable,
        [string[]]$BaseArguments,
        [int]$Workers
    )

    $regionWorker = {
        param($Bucket, [string]$Executable, [string[]]$Arguments)

        $location = & $Executable @Arguments s3api get-bucket-location `
            --bucket $Bucket.Name --query LocationConstraint --output text 2>&1
        if ($LASTEXITCODE -ne 0) {
            return [PSCustomObject]@{
                Bucket = $Bucket
                Region = ''
                Error = ($location -join [Environment]::NewLine)
            }
        }

        $region = ([string]$location).Trim()
        if ([string]::IsNullOrWhiteSpace($region) -or $region -eq 'None') {
            $region = 'us-east-1'
        }
        elseif ($region -eq 'EU') {
            $region = 'eu-west-1'
        }

        [PSCustomObject]@{ Bucket = $Bucket; Region = $region; Error = '' }
    }

    $regionWorkerText = $regionWorker.ToString()
    if ($PSVersionTable.PSVersion.Major -ge 7 -and $Workers -gt 1) {
        $bucketRegions = @(
            $Buckets | ForEach-Object -Parallel {
                $worker = [scriptblock]::Create($using:regionWorkerText)
                & $worker $_ $using:AwsExecutable $using:BaseArguments
            } -ThrottleLimit $Workers
        )
    }
    else {
        $bucketRegions = @(
            foreach ($bucket in $Buckets) {
                & $regionWorker $bucket $AwsExecutable $BaseArguments
            }
        )
    }

    $resultsByBucket = @{}
    foreach ($bucketRegion in $bucketRegions) {
        $bucketName = [string]$bucketRegion.Bucket.Name
        $resultsByBucket[$bucketName] = [PSCustomObject]@{
            BucketName = $bucketName
            Region = $bucketRegion.Region
            CreationDate = $bucketRegion.Bucket.CreationDate
            ObjectCount = [long]0
            SizeBytes = [long]0
            Tiers = @{}
            Error = $bucketRegion.Error
            ElapsedSeconds = [double]0
            TierCountsAvailable = $false
            MetricTimestamp = ''
        }
    }

    $startTime = (Get-Date).ToUniversalTime().AddDays(-3).ToString('o')
    $endTime = (Get-Date).ToUniversalTime().ToString('o')
    $validBuckets = @($bucketRegions | Where-Object { -not $_.Error })

    foreach ($regionGroup in ($validBuckets | Group-Object Region)) {
        $region = $regionGroup.Name
        $regionalBucketNames = @($regionGroup.Group.Bucket.Name)

        $metricJson = & $AwsExecutable @BaseArguments cloudwatch list-metrics `
            --namespace AWS/S3 `
            --metric-name BucketSizeBytes `
            --region $region `
            --output json
        if ($LASTEXITCODE -ne 0) {
            foreach ($bucketName in $regionalBucketNames) {
                $resultsByBucket[$bucketName].Error = 'Unable to list CloudWatch S3 metrics.'
            }
            continue
        }

        $sizeMetrics = @(
            ($metricJson | ConvertFrom-Json).Metrics |
                ForEach-Object {
                    $dimensionMap = @{}
                    foreach ($dimension in $_.Dimensions) {
                        $dimensionMap[$dimension.Name] = $dimension.Value
                    }
                    if (
                        $dimensionMap.BucketName -in $regionalBucketNames -and
                        $dimensionMap.StorageType
                    ) {
                        [PSCustomObject]@{
                            BucketName = $dimensionMap.BucketName
                            StorageType = $dimensionMap.StorageType
                        }
                    }
                } |
                Sort-Object BucketName, StorageType -Unique
        )

        $queries = [System.Collections.Generic.List[object]]::new()
        $queryMap = @{}

        foreach ($bucketName in ($regionalBucketNames | Sort-Object)) {
            $queryId = "m$($queries.Count)"
            $queryMap[$queryId] = @{
                BucketName = $bucketName
                Kind = 'Count'
                StorageType = 'AllStorageTypes'
            }
            $queries.Add([ordered]@{
                Id = $queryId
                MetricStat = [ordered]@{
                    Metric = [ordered]@{
                        Namespace = 'AWS/S3'
                        MetricName = 'NumberOfObjects'
                        Dimensions = @(
                            [ordered]@{ Name = 'BucketName'; Value = $bucketName },
                            [ordered]@{ Name = 'StorageType'; Value = 'AllStorageTypes' }
                        )
                    }
                    Period = 86400
                    Stat = 'Average'
                }
                ReturnData = $true
            })
        }

        foreach ($metric in $sizeMetrics) {
            $queryId = "m$($queries.Count)"
            $queryMap[$queryId] = @{
                BucketName = $metric.BucketName
                Kind = 'Size'
                StorageType = $metric.StorageType
            }
            $queries.Add([ordered]@{
                Id = $queryId
                MetricStat = [ordered]@{
                    Metric = [ordered]@{
                        Namespace = 'AWS/S3'
                        MetricName = 'BucketSizeBytes'
                        Dimensions = @(
                            [ordered]@{ Name = 'BucketName'; Value = $metric.BucketName },
                            [ordered]@{ Name = 'StorageType'; Value = $metric.StorageType }
                        )
                    }
                    Period = 86400
                    Stat = 'Average'
                }
                ReturnData = $true
            })
        }

        foreach ($queryBatch in (Split-Array -Items $queries.ToArray() -Size 500)) {
            $queryJson = ConvertTo-Json -InputObject @($queryBatch) -Depth 10 -Compress
            $dataJson = & $AwsExecutable @BaseArguments cloudwatch get-metric-data `
                --metric-data-queries $queryJson `
                --start-time $startTime `
                --end-time $endTime `
                --scan-by TimestampDescending `
                --region $region `
                --output json
            if ($LASTEXITCODE -ne 0) {
                foreach ($bucketName in $regionalBucketNames) {
                    $resultsByBucket[$bucketName].Error = 'Unable to read CloudWatch S3 metrics.'
                }
                continue
            }

            foreach ($metricResult in (($dataJson | ConvertFrom-Json).MetricDataResults)) {
                if (-not $metricResult.Values -or -not $metricResult.Timestamps) { continue }
                $mapping = $queryMap[$metricResult.Id]
                $bucketResult = $resultsByBucket[$mapping.BucketName]
                $value = [double]$metricResult.Values[0]
                $timestamp = [string]$metricResult.Timestamps[0]

                if (
                    [string]::IsNullOrWhiteSpace($bucketResult.MetricTimestamp) -or
                    $timestamp -gt $bucketResult.MetricTimestamp
                ) {
                    $bucketResult.MetricTimestamp = $timestamp
                }

                if ($mapping.Kind -eq 'Count') {
                    $bucketResult.ObjectCount = [long][Math]::Round($value)
                }
                else {
                    $tier = Convert-StorageTypeToTier $mapping.StorageType
                    if (-not $bucketResult.Tiers.ContainsKey($tier)) {
                        $bucketResult.Tiers[$tier] = @{
                            ObjectCount = [long]0
                            SizeBytes = [long]0
                        }
                    }
                    $bytes = [long][Math]::Round($value)
                    $bucketResult.Tiers[$tier].SizeBytes += $bytes
                    $bucketResult.SizeBytes += $bytes
                }
            }
        }
    }

    foreach ($bucketResult in $resultsByBucket.Values) {
        if (-not $bucketResult.Error -and -not $bucketResult.MetricTimestamp) {
            $bucketResult.Error = 'No CloudWatch daily storage metrics found in the last 3 days.'
        }
    }

    @($resultsByBucket.Values | Sort-Object BucketName)
}

$awsCommand = Get-Command aws -ErrorAction SilentlyContinue
if (-not $awsCommand) {
    throw 'AWS CLI v2 was not found in PATH.'
}

$awsExecutable = $awsCommand.Source
$baseArguments = @(Get-AwsBaseArguments -Profile $ProfileName)
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
        TierCountsAvailable = $true
        MetricTimestamp = ''
    }
}
$scanBucketText = $scanBucket.ToString()

Write-Host "AWS account: $($identity.Account)"
$overallTimer = [System.Diagnostics.Stopwatch]::StartNew()

if ($Mode -eq 'Fast') {
    Write-Host "Found $($buckets.Count) buckets; reading daily CloudWatch storage metrics..."
    $results = @(
        Get-FastCloudWatchResults `
            -Buckets $buckets `
            -AwsExecutable $awsExecutable `
            -BaseArguments $baseArguments `
            -Workers $Workers
    )
}
else {
    Write-Host "Found $($buckets.Count) buckets; scanning with $Workers worker(s)..."
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
        'Metric Timestamp' = $result.MetricTimestamp
        'Tier Counts Available' = $result.TierCountsAvailable
        'Error' = $result.Error
    }

    foreach ($tierName in $tierNames) {
        $usage = $result.Tiers[$tierName]
        $count = if (-not $result.TierCountsAvailable) {
            ''
        }
        elseif ($usage) {
            [long]$usage.ObjectCount
        }
        else {
            [long]0
        }
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
$tierCountsAvailable = @(
    $successfulResults | Where-Object { -not $_.TierCountsAvailable }
).Count -eq 0
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
    'Metric Timestamp' = (
        $successfulResults.MetricTimestamp |
            Where-Object { $_ } |
            Sort-Object -Descending |
            Select-Object -First 1
    )
    'Tier Counts Available' = $tierCountsAvailable
    'Error' = ''
}
foreach ($tierName in $tierNames) {
    $usage = $tierTotals[$tierName]
    $count = if (-not $tierCountsAvailable) {
        ''
    }
    elseif ($usage) {
        [long]$usage.ObjectCount
    }
    else {
        [long]0
    }
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
        if ($tierCountsAvailable) {
            Write-Host (
                '  {0,-24} {1,15:N0} objects  {2,14}  ({3:N0} bytes)' -f `
                    $_.Name,
                    $_.Value.ObjectCount,
                    (Format-Size $_.Value.SizeBytes),
                    $_.Value.SizeBytes
            )
        }
        else {
            Write-Host (
                '  {0,-24} {1,15} objects  {2,14}  ({3:N0} bytes)' -f `
                    $_.Name,
                    'N/A',
                    (Format-Size $_.Value.SizeBytes),
                    $_.Value.SizeBytes
            )
        }
    }

if ($Mode -eq 'Fast') {
    $latestMetric = (
        $successfulResults.MetricTimestamp |
            Where-Object { $_ } |
            Sort-Object -Descending |
            Select-Object -First 1
    )
    Write-Host "`nCloudWatch metrics as of: $latestMetric"
    Write-Host 'Tier object counts are unavailable in standard CloudWatch S3 metrics.'
}

Write-Host "`nCSV written to $OutputPath"
Write-Host ('Completed in {0:N1}s' -f $overallTimer.Elapsed.TotalSeconds)

if (@($results | Where-Object { $_.Error }).Count -gt 0) {
    exit 1
}
