# AWS S3 Bucket Report Script
# This script uses AWS Tools for PowerShell to gather S3 bucket information
param(
    [string]$ProfileName = "TempSession",
    [switch]$SkipLargeBuckets = $false,  # Set to $true to skip buckets with more than 1000 objects
    [switch]$AllRegions  # Process all regions by default
)

# Set default for AllRegions if not specified
if (-not $PSBoundParameters.ContainsKey('AllRegions')) {
    $AllRegions = $true
}

# Function to get AWS regions (US only)
function Get-AWSRegions {
    try {
        # Include only US regions
        $regions = @(
            'us-east-1',  # US East (N. Virginia)
            'us-east-2',  # US East (Ohio)
            'us-west-1',  # US West (N. California)
            'us-west-2'   # US West (Oregon)
        )
        return $regions | Sort-Object
    } catch {
        Write-Warning "Error getting AWS regions. Defaulting to us-east-1"
        return @('us-east-1')
    }
}

# Set AWS profile and region
Set-AWSCredential -ProfileName $ProfileName

# Set default region if not specified
if (-not $Regions -or $Regions.Count -eq 0) {
    $Regions = @('us-east-1')
}

# Set max objects to a very high number if not skipping large buckets
$maxObjects = if ($SkipLargeBuckets) { 1000 } else { [int]::MaxValue }

# Initialize AWS configuration with the first region
Set-DefaultAWSRegion -Region $Regions[0] -Scope Script

# Initialize storage class tracking
$allStorageClasses = @{}
$totalStorageByClass = @{}
$totalObjectsByClass = @{}

# Function to format size in human-readable format
function Format-Size {
    param([double]$bytes)
    if ($bytes -eq 0) { return "0 KB" }
    if ($bytes -ge 1GB) {
        return "{0:N2} GB" -f ($bytes/1GB)
    } elseif ($bytes -ge 1MB) {
        return "{0:N2} MB" -f ($bytes/1MB)
    } else {
        return "{0:N2} KB" -f ($bytes/1KB)
    }
}

# Check if AWS Tools module is installed
$requiredModules = @("AWS.Tools.Installer", "AWS.Tools.Common", "AWS.Tools.S3")

foreach ($module in $requiredModules) {
    if (-not (Get-Module -ListAvailable -Name $module)) {
        try {
            Install-Module -Name $module -Force -Scope CurrentUser -ErrorAction Stop
            Import-Module $module -Force -ErrorAction Stop
        } catch {
            Write-Error "Failed to install/import module $module. Please install it manually: $_"
            exit 1
        }
    }
}

# Set AWS profile
Set-AWSCredential -ProfileName $ProfileName

# Initialize results
$allResults = @()
$global:regionStats = @{}

# Get all AWS regions if AllRegions is specified
if ($AllRegions) {
    $Regions = Get-AWSRegions
    Write-Host "`nProcessing all available AWS regions:"
    $Regions | ForEach-Object { Write-Host "- $_" }
}

# First, get all buckets across all regions
Write-Host "`nFetching all S3 buckets..."
try {
    $allBuckets = Get-S3Bucket -ErrorAction Stop
    Write-Host "  Found $($allBuckets.Count) buckets in total"
} catch {
    Write-Error "Error listing S3 buckets: $_"
    exit 1
}

# Process each region
foreach ($Region in $Regions) {
    Write-Host "`nProcessing region: $Region"
    
    try {
        Write-Host "`nFetching buckets located in region: $Region"
        
        # Filter buckets by region
        $bucketsInRegion = @()
        $bucketsProcessed = 0
        $totalBuckets = $allBuckets.Count
        
        Write-Host "  Checking locations of $totalBuckets buckets..."
        
        foreach ($bucket in $allBuckets) {
            $bucketsProcessed++
            if ($bucketsProcessed % 10 -eq 0 -or $bucketsProcessed -eq $totalBuckets) {
                Write-Progress -Activity "Checking bucket regions" -Status "Processed $bucketsProcessed of $totalBuckets" -PercentComplete (($bucketsProcessed / $totalBuckets) * 100)
            }
            
            try {
                $location = Get-S3BucketLocation -BucketName $bucket.BucketName -ErrorAction Stop
                $bucketRegion = if ([string]::IsNullOrEmpty($location.Value)) { 'us-east-1' } else { $location.Value }
                
                if ($bucketRegion -eq $Region) {
                    $bucketsInRegion += $bucket
                }
            } catch {
                Write-Warning "  Could not determine region for bucket $($bucket.BucketName): $_"
            }
        }
        Write-Progress -Activity "Checking bucket regions" -Completed
        
        if ($bucketsInRegion.Count -eq 0) {
            Write-Host "  No buckets found in region $Region"
            continue
        }
        
        try {
            # Set the region for this iteration
            Set-DefaultAWSRegion -Region $Region -Scope Script
            
            # Use the pre-filtered buckets for this region
            $buckets = $bucketsInRegion
            
            # Output the list of buckets in this region
            Write-Host "  Found $($buckets.Count) buckets in region $Region"
            if ($buckets.Count -gt 0) {
                Write-Host "  Processing buckets in $Region"
                if ($buckets.Count -le 10) {
                    $buckets | ForEach-Object { Write-Host ("    - {0}" -f $_.BucketName) }
                } else {
                    $buckets[0..4] | ForEach-Object { Write-Host ("    - {0}" -f $_.BucketName) }
                    Write-Host ("    ... and {0} more" -f ($buckets.Count - 5))
                }
            }
            
            # Initialize storage tracking for this region
            $allStorageClasses = @{}
            $results = @()
            $totalStorageByClass = @{}
            $totalObjectsByClass = @{}
            
            # Process each bucket with progress
            $bucketCount = $buckets.Count
            $current = 0
            
            # Skip if no buckets in this region
            if ($bucketCount -eq 0) {
                continue
            }
            
            # Initialize region stats for this region if not exists
            if (-not $global:regionStats.ContainsKey($Region)) {
                $global:regionStats[$Region] = @{
                    Buckets = 0
                    Objects = 0
                    Storage = 0
                    StorageByClass = @{}
                    ObjectsByClass = @{}
                }
            }
        } catch {
            Write-Warning "Error listing buckets: $_"
            continue
        }

        # Initialize storage tracking for this region
        $allStorageClasses = @{}
        $results = @()
        $totalStorageByClass = @{}
        $totalObjectsByClass = @{}

        # Process each bucket with progress
        $bucketCount = $buckets.Count
        $current = 0
        $results = @()
        
        # Initialize region stats for this region if not exists
        if (-not $global:regionStats.ContainsKey($Region)) {
            $global:regionStats[$Region] = @{
                Buckets = 0
                Objects = 0
                Storage = 0
                StorageByClass = @{}
                ObjectsByClass = @{}
            }
        }
        
        # Initialize storage tracking for this region
        $allStorageClasses = @{}
        $results = @()
        $totalStorageByClass = @{}
        $totalObjectsByClass = @{}

        foreach ($bucket in $buckets) {
            $current++
            $bucketName = $bucket.BucketName
            $startTime = Get-Date
            $requestCount = 0
            
            # Show progress
            $progressParams = @{
                Activity = "Analyzing S3 Buckets in $Region"
                Status = "Processing bucket $current of $bucketCount - $bucketName"
                PercentComplete = [math]::Min(($current / $bucketCount * 100), 100)
                CurrentOperation = "Bucket: $bucketName"
            }
            
            # Get bucket metrics from CloudWatch for validation
            $metrics = $null
            try {
                $endTime = Get-Date
                $startTime = $endTime.AddDays(-1)
                
                # Get size metrics
                $sizeData = Get-CWMetricData -Namespace AWS/S3 -MetricName BucketSizeBytes `
                    -StartTime $startTime -EndTime $endTime -Period 86400 `
                    -Statistics Average -Dimensions @{Name="BucketName";Value=$bucketName}, @{Name="StorageType";Value="StandardStorage"} `
                    -Region $Region -ErrorAction SilentlyContinue
                
                # Get object count metrics
                $countData = Get-CWMetricData -Namespace AWS/S3 -MetricName NumberOfObjects `
                    -StartTime $startTime -EndTime $endTime -Period 86400 `
                    -Statistics Average -Dimensions @{Name="BucketName";Value=$bucketName}, @{Name="StorageType";Value="AllStorageTypes"} `
                    -Region $Region -ErrorAction SilentlyContinue
            } catch {
                Write-Warning "Error getting CloudWatch metrics for bucket $bucketName : $_"
            }
            
            Write-Progress @progressParams
            
            try {
                try {
                    # Get bucket location
                    $location = Get-S3BucketLocation -BucketName $bucketName -ErrorAction Stop
                    $bucketRegion = if ([string]::IsNullOrEmpty($location.Value)) { 'us-east-1' } else { $location.Value }
                    
                    # List objects in the bucket with pagination and timeout
                    Write-Host "  Analyzing bucket: $bucketName (Region: $bucketRegion)"
                    
                    $startTime = Get-Date
                    $objects = @()
                    $totalSize = 0
                    $objectCount = 0
                    $storageByClass = @{}
                    $nextToken = $null
                    $isTruncated = $false
                    
                    do {
                        try {
                            # Get objects from S3 with pagination
                            $params = @{
                                BucketName = $bucketName
                                Region = $bucketRegion
                                ErrorAction = 'Stop'
                            }
                            
                            if ($nextToken) {
                                $params['ContinuationToken'] = $nextToken
                            }
                            
                            $response = Get-S3Object @params
                            $isTruncated = $response.IsTruncated
                            $nextToken = $response.NextContinuationToken
                            
                            if ($response.Contents) {
                                $batchSize = $response.Contents.Count
                                $objectCount += $batchSize
                                
                                foreach ($obj in $response.Contents) {
                                    $totalSize += $obj.Size
                                    
                                    # Track storage class with standardization
                                    $class = if ($obj.StorageClass) { $obj.StorageClass.ToString().Trim().ToUpper() } else { 'STANDARD' }
                                    
                                    # Standardize storage class names
                                    switch -Wildcard ($class) {
                                        "STANDARD*" { $class = "STANDARD" }
                                        "STANDARD_IA*" { $class = "STANDARD_IA" }
                                        "INTELLIGENT_TIERING*" { $class = "INTELLIGENT_TIERING" }
                                        "GLACIER*" { $class = "GLACIER" }
                                        "DEEP_ARCHIVE*" { $class = "DEEP_ARCHIVE" }
                                        "GLACIER_IR*" { $class = "GLACIER_IR" }
                                        "ONEZONE_IA*" { $class = "ONEZONE_IA" }
                                        "REDUCED_REDUNDANCY*" { $class = "REDUCED_REDUNDANCY" }
                                        "OUTPOSTS*" { $class = "OUTPOSTS" }
                                        default { $class = $class.ToUpper() }
                                    }
                                    
                                    if (-not $storageByClass.ContainsKey($class)) {
                                        $storageByClass[$class] = 0
                                    }
                                    $storageByClass[$class] += $obj.Size
                                    
                                    # Only add to objects array if we're not skipping large buckets
                                    if (-not $SkipLargeBuckets -or $objectCount -le $maxObjects) {
                                        $objects += $obj
                                    }
                                }
                                
                                # Update progress
                                $elapsed = (Get-Date) - $startTime
                                $rate = if ($elapsed.TotalSeconds -gt 0) { [math]::Round($objectCount / $elapsed.TotalSeconds, 2) } else { 0 }
                                $status = "Fetched $objectCount objects | ${rate} obj/sec | $(Format-Size $totalSize)"
                                Write-Progress -Activity "Processing $bucketName" -Status $status -PercentComplete ([math]::Min(($objectCount / $maxObjects) * 100, 100))
                                
                                # Check if we've reached the maximum objects to process
                                if ($objectCount -ge $maxObjects) {
                                    if ($SkipLargeBuckets) {
                                        Write-Warning "  Reached maximum object limit of $maxObjects for bucket $bucketName. Skipping remaining objects."
                                        break
                                    } else {
                                        Write-Verbose "  Reached maximum object limit of $maxObjects for bucket $bucketName. Continuing with partial results."
                                    }
                                }
                                
                                # Add a small delay to avoid throttling
                                if ($isTruncated) {
                                    Start-Sleep -Milliseconds 200
                                }
                            }
                            
                        } catch {
                            $errorMsg = $_.Exception.Message
                            if ($errorMsg -like "*AccessDenied*" -or $errorMsg -like "*Forbidden*") {
                                Write-Warning "  Access denied to list objects in bucket $bucketName"
                                break
                            }
                            Write-Error "  Error processing bucket $bucketName : $errorMsg"
                            break
                        }
                        
                    } while ($isTruncated -and $objectCount -lt $maxObjects)
                    
                    # Clear progress when done
                    Write-Progress -Activity "Processing $bucketName" -Completed
                    
                    # Compare with CloudWatch metrics if available
                    if ($metrics.SizeBytes -and $totalSize -gt 0) {
                        $sizeDiff = $metrics.SizeBytes - $totalSize
                        $sizeDiffPct = [math]::Abs(($sizeDiff / $metrics.SizeBytes) * 100)
                        
                        if ($sizeDiffPct -gt 10) {
                            $sizeFormatted = Format-Size $totalSize
                            $metricsFormatted = Format-Size $metrics.SizeBytes
                            Write-Warning "  Size mismatch: API $sizeFormatted vs CloudWatch $metricsFormatted (${sizeDiffPct:N1}% difference)"
                        }
                    }
                    
                    if ($metrics.ObjectCount -and $objectCount -gt 0) {
                        $countDiff = $metrics.ObjectCount - $objectCount
                        $countDiffPct = [math]::Abs(($countDiff / $metrics.ObjectCount) * 100)
                        
                        if ($countDiffPct -gt 10) {
                            Write-Warning "  Object count mismatch: API $objectCount vs CloudWatch $($metrics.ObjectCount) (${countDiffPct:N1}% difference)"
                        }
                    }
                    
                    # Add bucket results to region stats
                    if ($totalSize -gt 0 -or $objectCount -gt 0) {
                        $global:regionStats[$Region].Buckets++
                        $global:regionStats[$Region].Objects += $objectCount
                        $global:regionStats[$Region].Storage += $totalSize
                        
                        # Update storage by class
                        foreach ($class in $storageByClass.Keys) {
                            if (-not $global:regionStats[$Region].StorageByClass.ContainsKey($class)) {
                                $global:regionStats[$Region].StorageByClass[$class] = 0
                                $global:regionStats[$Region].ObjectsByClass[$class] = 0
                            }
                            $global:regionStats[$Region].StorageByClass[$class] += $storageByClass[$class]
                            $global:regionStats[$Region].ObjectsByClass[$class] += $objects.Where({ $_.StorageClass -eq $class }).Count
                        }
                    }
                    
                    Write-Host "    Found $objectCount objects in bucket $bucketName (Total size: $(Format-Size $totalSize))"
                }
                
                # Initialize storage summary for this bucket
                $storageSummary = @{}
                $bucketSize = $totalSize
                $bucketObjects = $objectCount
                
                # Create result object for this bucket
                $result = [PSCustomObject]@{
                    BucketName = $bucketName
                    Region = $Region
                    ObjectCount = $objectCount
                    TotalSize = $totalSize
                    TotalSizeFormatted = Format-Size $totalSize
                    StorageByClass = $storageByClass
                    IsTruncated = $isTruncated
                    LastKey = $lastKey
                    RequestCount = $requestCount
                    Timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
                }
                
                Write-Host "    Processing $objectCount objects..."
                
                # Initialize storage class tracking for this bucket
                $bucketStorageByClass = @{}
                
                # Calculate storage by class
                if ($objects) {
                    foreach ($obj in $objects) {
                        $class = if ($obj.StorageClass) { $obj.StorageClass } else { 'STANDARD' }
                        
                        if (-not $storageSummary.ContainsKey($class)) {
                            $storageSummary[$class] = @{
                                Size = 0
                                Count = 0
                            }
                        }
                        
                        $storageSummary[$class].Size += $obj.Size
                        $storageSummary[$class].Count++
                        $bucketSize += $obj.Size
                        $bucketObjects++
                        
                        # Track all unique storage classes
                        if (-not $allStorageClasses.ContainsKey($class)) {
                            $allStorageClasses[$class] = $true
                            $totalStorageByClass[$class] = 0
                            $totalObjectsByClass[$class] = 0
                            $regionStats.StorageByClass[$class] = 0
                            $regionStats.ObjectsByClass[$class] = 0
                            $bucketStorageByClass[$class] = 0
                        }
                        
                        # Update bucket storage by class
                        if (-not $bucketStorageByClass.ContainsKey($class)) {
                            $bucketStorageByClass[$class] = 0
                        }
                        $bucketStorageByClass[$class] += $obj.Size
                    }
                }
                
                # Initialize storage class tracking if needed
                if (-not $script:storageClassesInitialized) {
                    $script:allStorageClasses = @{}
                    $script:storageClassesInitialized = $true
                }
                
                # Add storage class breakdown to result
                $result | Add-Member -MemberType NoteProperty -Name 'StorageByClass' -Value $bucketStorageByClass -Force
                
                # Add formatted size to result
                $result | Add-Member -MemberType NoteProperty -Name 'TotalSizeFormatted' -Value (Format-Size $bucketSize) -Force
                
                # Add timestamp to result
                $result | Add-Member -MemberType NoteProperty -Name 'Timestamp' -Value (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') -Force
                
                # Track all storage classes found and add to result
                if ($null -ne $bucketStorageByClass) {
                    foreach ($class in $bucketStorageByClass.Keys) {
                        if (-not $script:allStorageClasses.ContainsKey($class)) {
                            $script:allStorageClasses[$class] = $true
                        }
                        
                        # Add storage class size to result with sanitized property name
                        $propertyName = "SC_$($class -replace '[^a-zA-Z0-9]', '_')"
                        try {
                            $result | Add-Member -MemberType NoteProperty -Name $propertyName -Value (Format-Size $bucketStorageByClass[$class]) -Force -ErrorAction Stop
                        } catch {
                            Write-Warning "Failed to add property $propertyName : $_"
                        }
                    }
                }
                
                # Add storage class columns
                if ($null -ne $script:allStorageClasses -and $script:allStorageClasses.Count -gt 0) {
                    $storageClassList = $script:allStorageClasses.Keys | Sort-Object
                    foreach ($class in $storageClassList) {
                        $size = if ($storageSummary.ContainsKey($class)) { $storageSummary[$class].Size } else { 0 }
                        $count = if ($storageSummary.ContainsKey($class)) { $storageSummary[$class].Count } else { 0 }
                        
                        # Add storage class size and count to result with formatted size
                        $result | Add-Member -MemberType NoteProperty -Name $class -Value (Format-Size $size) -Force
                        $result | Add-Member -MemberType NoteProperty -Name "${class}_Objects" -Value $count -Force
                        
                        # Update totals
                        if (-not $totalStorageByClass.ContainsKey($class)) {
                            $totalStorageByClass[$class] = 0
                            $totalObjectsByClass[$class] = 0
                        }
                        $totalStorageByClass[$class] += $size
                        $totalObjectsByClass[$class] += $count
                    }
                }
                    
                # Update region stats for each storage class
                if ($null -ne $script:allStorageClasses -and $script:allStorageClasses.Count -gt 0) {
                    $storageClassList = $script:allStorageClasses.Keys | Sort-Object
                    foreach ($class in $storageClassList) {
                        $size = if ($storageSummary.ContainsKey($class)) { $storageSummary[$class].Size } else { 0 }
                        $count = if ($storageSummary.ContainsKey($class)) { $storageSummary[$class].Count } else { 0 }
                        
                        # Initialize storage class in region stats if not exists
                        if (-not $global:regionStats[$Region].StorageByClass.ContainsKey($class)) {
                            $global:regionStats[$Region].StorageByClass[$class] = 0
                            $global:regionStats[$Region].ObjectsByClass[$class] = 0
                        }
                        
                        # Update region stats
                        $global:regionStats[$Region].StorageByClass[$class] += $size
                        $global:regionStats[$Region].ObjectsByClass[$class] += $count
                    }
                }
                }
                
                # Update region stats
                $global:regionStats[$Region].Buckets++
                $global:regionStats[$Region].Objects += $bucketObjects
                $global:regionStats[$Region].Storage += $bucketSize
                
                Write-Host ("    Processed bucket {0}: {1} objects, {2} total" -f $bucketName, $bucketObjects, (Format-Size $bucketSize))
                
                # Add to results if we have data
                if ($result -and $result.ObjectCount -gt 0) {
                    $results += $result
                    $allResults += $result
                    
                    # Update region totals
                    $global:regionStats[$Region].Buckets++
                    $global:regionStats[$Region].Objects += $result.ObjectCount
                    $global:regionStats[$Region].Storage += $result.TotalSize
                    
                    # Update storage by class
                    if ($result.StorageByClass) {
                        foreach ($class in $result.StorageByClass.Keys) {
                            if (-not $global:regionStats[$Region].StorageByClass.ContainsKey($class)) {
                                $global:regionStats[$Region].StorageByClass[$class] = 0
                                $global:regionStats[$Region].ObjectsByClass[$class] = 0
                            }
                            $global:regionStats[$Region].StorageByClass[$class] += $result.StorageByClass[$class]
                            $global:regionStats[$Region].ObjectsByClass[$class] += $result.StorageByClass[$class] / 1KB  # Approximate object count
                        }
                    }
                }
                
            } catch {
                Write-Warning "Error processing bucket $bucketName : $_"
                continue
            }
        }

        # Output results for this region
        if ($results.Count -gt 0) {
            Write-Host ("`nBucket Summary for {0}:" -f $Region)
            $results | Format-Table -AutoSize
            
            # Add to all results
            $allResults += $results
            
            # Output region statistics
            if ($global:regionStats.ContainsKey($Region)) {
                $regionData = $global:regionStats[$Region]
                Write-Host "`nRegion $Region Statistics:"
                Write-Host ("- {0} buckets" -f $regionData.Buckets)
                Write-Host ("- {0:N0} objects" -f $regionData.Objects)
                Write-Host ("- {0} total storage" -f (Format-Size $regionData.Storage))
                
                if ($regionData.StorageByClass.Count -gt 0) {
                    Write-Host "`nStorage by class:"
                    foreach ($class in ($regionData.StorageByClass.Keys | Sort-Object)) {
                        $size = $regionData.StorageByClass[$class]
                        $count = $regionData.ObjectsByClass[$class]
                        if ($size -gt 0) {
                            Write-Host ("  - {0,-12}: {1,10} in {2} objects" -f $class, (Format-Size $size), $count)
                        }
                    }
                }
            }
        }
        
    } catch {
        Write-Warning "Error processing region $Region : $_"
        continue
    }
}

# Output results as CSV
$csvPath = Join-Path -Path (Get-Location) -ChildPath "s3-bucket-summary.csv"
$allResults | Export-Csv -Path $csvPath -NoTypeInformation -Force
Write-Host "`nCSV output saved to: $csvPath"

# Initialize summary statistics
$summaryStats = @{
    TotalBuckets = 0
    TotalObjects = 0
    TotalStorage = 0
    StorageByClass = @{}
    ObjectsByClass = @{}
}

# Create a new hashtable to store region stats with proper structure
$regionSummaries = @{}

# Collect data across all regions
foreach ($region in $regionStats.Keys) {
    if ($region -is [string] -and $region -match '^[a-z0-9-]+$') {  # Only process valid region names
        $stats = $regionStats[$region]
        $summaryStats.TotalBuckets += $stats.Buckets
        $summaryStats.TotalObjects += $stats.Objects
        $summaryStats.TotalStorage += $stats.Storage
        
        # Store region summary
        $regionSummaries[$region] = @{
            Buckets = $stats.Buckets
            Objects = $stats.Objects
            Storage = $stats.Storage
            StorageByClass = @{}
            ObjectsByClass = @{}
        }
        
        # Update storage by class
        foreach ($class in $stats.StorageByClass.Keys) {
            if (-not $summaryStats.StorageByClass.ContainsKey($class)) {
                $summaryStats.StorageByClass[$class] = 0
                $summaryStats.ObjectsByClass[$class] = 0
                $regionSummaries[$region].StorageByClass[$class] = 0
                $regionSummaries[$region].ObjectsByClass[$class] = 0
            }
            $summaryStats.StorageByClass[$class] += $stats.StorageByClass[$class]
            $summaryStats.ObjectsByClass[$class] += $stats.ObjectsByClass[$class]
            $regionSummaries[$region].StorageByClass[$class] += $stats.StorageByClass[$class]
            $regionSummaries[$region].ObjectsByClass[$class] += $stats.ObjectsByClass[$class]
        }
    }
}

# Output summary report
Write-Host "`nSUMMARY REPORT"
Write-Host "=============="
Write-Host ("Total Buckets: {0}" -f $summaryStats.TotalBuckets)
Write-Host ("Total Objects: {0:N0}" -f $summaryStats.TotalObjects)
Write-Host ("Total Storage: {0}" -f (Format-Size $summaryStats.TotalStorage))

# Output storage by class
if ($summaryStats.StorageByClass.Count -gt 0) {
    Write-Host "`nSTORAGE BY STORAGE CLASS:"
    $summaryStats.StorageByClass.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object {
        $class = $_.Key
        $storage = $_.Value
        $objects = $summaryStats.ObjectsByClass[$class]
        if ($storage -gt 0) {
            $percent = if ($summaryStats.TotalStorage -gt 0) { ($storage / $summaryStats.TotalStorage) * 100 } else { 0 }
            Write-Host ("- {0,-15}: {1,10} in {2,6} objects ({3:N1}% of total)" -f 
                $class, 
                (Format-Size $storage), 
                $objects, 
                $percent)
        }
    }
}

# Output per-region details
Write-Host "`nDETAILED STORAGE BY REGION:"
Write-Host "========================="

foreach ($region in $regionSummaries.Keys | Sort-Object) {
    $stats = $regionSummaries[$region]
    Write-Host ("`nREGION: {0}" -f $region.ToUpper())
    Write-Host ("{0} Buckets, {1:N0} Objects, {2} Total Storage" -f 
        $stats.Buckets, $stats.Objects, (Format-Size $stats.Storage))
    
    if ($stats.StorageByClass.Count -gt 0) {
        Write-Host "  Storage by Class:"
        $stats.StorageByClass.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object {
            $class = $_.Key
            $storage = $_.Value
            $objects = $stats.ObjectsByClass[$class]
            if ($storage -gt 0) {
                Write-Host ("  - {0,-15}: {1,10} in {2,6} objects" -f 
                    $class, 
                    (Format-Size $storage), 
                    $objects)
            }
        }
    }
}

# Clean up progress bars
Write-Progress -Activity "S3 Bucket Analysis" -Completed

# Output final summary
$totalBuckets = ($allResults | Select-Object -ExpandProperty BucketName -Unique).Count
$totalObjects = ($allResults | Measure-Object -Sum ObjectCount -ErrorAction SilentlyContinue).Sum
$totalSize = 0

# Calculate total storage and storage by class
$storageByClass = @{}
$objectsByClass = @{}

# Initialize storage classes
foreach ($class in $allStorageClasses.Keys) {
    $storageByClass[$class] = 0
    $objectsByClass[$class] = 0
}

# Process all results
foreach ($result in $allResults) {
    # Calculate total size
    if ($result.TotalSize -match '([\d.]+)\s*(\w+)') {
        $val = [double]$matches[1]
        $unit = $matches[2].ToUpper()
        $size = 0
        switch ($unit) {
            'KB' { $size = $val * 1KB }
            'MB' { $size = $val * 1MB }
            'GB' { $size = $val * 1GB }
            'TB' { $size = $val * 1TB }
            default { $size = $val }
        }
        $totalSize += $size
    }
    
    # Process storage classes
    foreach ($class in $allStorageClasses.Keys) {
        $propertyName = "SC_$($class -replace '[^a-zA-Z0-9]', '_')"  # Match the sanitized property name
        if ($result.PSObject.Properties[$propertyName]) {
            $sizeStr = $result.$propertyName
            if ($sizeStr -match '([\d.]+)\s*(\w+)') {
                $val = [double]$matches[1]
                $unit = $matches[2].ToUpper()
                $size = 0
                switch ($unit) {
                    'KB' { $size = $val * 1KB }
                    'MB' { $size = $val * 1MB }
                    'GB' { $size = $val * 1GB }
                    'TB' { $size = $val * 1TB }
                    default { $size = $val }
                }
                
                # Initialize storage class if it doesn't exist
                if (-not $storageByClass.ContainsKey($class)) {
                    $storageByClass[$class] = 0
                    $objectsByClass[$class] = 0
                }
                
                $storageByClass[$class] += $size
                $objectsByClass[$class] += $result.ObjectCount
            }
        }
    }
}

Write-Host "`n`n╔══════════════════════════════════╗"
Write-Host "║         FINAL SUMMARY           ║"
Write-Host "╠══════════════════════════════════╣"
Write-Host ("║ {0,-32} ║" -f ("Total Buckets: {0}" -f $totalBuckets))
Write-Host ("║ {0,-32} ║" -f ("Total Objects: {0:N0}" -f $totalObjects))
Write-Host ("║ {0,-32} ║" -f ("Total Storage: {0}" -f (Format-Size $totalSize)))
Write-Host "╚══════════════════════════════════╝"

# Output storage by class
$storageByClass = @{}
$objectsByClass = @{}

foreach ($result in $allResults) {
    foreach ($prop in $result.PSObject.Properties) {
        if ($prop.Name -like '*_Objects') {
            $class = $prop.Name -replace '_Objects$', ''
            if (-not $objectsByClass.ContainsKey($class)) {
                $objectsByClass[$class] = 0
                $storageByClass[$class] = 0
            }
            $objectsByClass[$class] += $prop.Value
            
            # Get corresponding storage size
            $sizeProp = $result.PSObject.Properties[$class]
            if ($sizeProp) {
                $size = 0
                if ($sizeProp.Value -match '([\d.]+) (\w+)') {
                    $val = [double]$matches[1]
                    $unit = $matches[2]
                    switch ($unit) {
                        'KB' { $size = $val * 1KB }
                        'MB' { $size = $val * 1MB }
                        'GB' { $size = $val * 1GB }
                        'TB' { $size = $val * 1TB }
                        default { $size = $val }
                    }
                }
                $storageByClass[$class] += $size
            }
        }
    }
}

if ($storageByClass.Count -gt 0) {
    Write-Host "`n╔══════════════════════════════════════════════════════════════════════════╗"
    Write-Host "║                    STORAGE BY STORAGE CLASS SUMMARY                     ║"
    Write-Host "╠══════════════════════════════════════════════════════════════════════════╣"
    
    # Calculate column widths
    $maxClassLength = ($storageByClass.Keys | ForEach-Object { $_.Length } | Measure-Object -Maximum).Maximum + 1
    $maxStorageLength = 15
    $maxObjectsLength = 15
    
    # Header
    Write-Host ("║ {0,-$maxClassLength} {1,$maxStorageLength} {2,$maxObjectsLength} {3,10}" -f 
        "STORAGE CLASS:", "STORAGE", "OBJECTS", "% OF TOTAL")
    Write-Host "╠══════════════════════════════════════════════════════════════════════════╣"
    
    $storageByClass.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object {
        $class = $_.Key
        $storage = $_.Value
        $objects = $objectsByClass[$class]
        
        $percent = if ($totalSize -gt 0) { ($storage / $totalSize * 100) } else { 0 }
        $storageStr = Format-Size $storage
        $objectsStr = $objects.ToString("N0")
        $percentStr = $percent.ToString("N1") + "%"
        
        Write-Host ("║ {0,-$maxClassLength} {1,$maxStorageLength} {2,$maxObjectsLength} {3,10}" -f 
            "$($class):", 
            $storageStr.PadLeft($maxStorageLength),
            $objectsStr.PadLeft($maxObjectsLength),
            $percentStr.PadLeft(8))
    }
    
    # Add totals row
    $totalStorageStr = Format-Size $totalSize
    $totalObjectsStr = $totalObjects.ToString("N0")
    
    Write-Host "╠══════════════════════════════════════════════════════════════════════════╣"
    Write-Host ("║ {0,-$maxClassLength} {1,$maxStorageLength} {2,$maxObjectsLength} {3,10}" -f 
        "TOTAL:", 
        $totalStorageStr.PadLeft($maxStorageLength),
        $totalObjectsStr.PadLeft($maxObjectsLength),
        "100.0%".PadLeft(8))
    Write-Host "╚══════════════════════════════════════════════════════════════════════════╝"
    
    # Detailed storage by region and class
    Write-Host "`n╔══════════════════════════════════════════════════════════════════════════╗"
    Write-Host "║                STORAGE BY REGION AND STORAGE CLASS                     ║"
    Write-Host "╠══════════════════════════════════════════════════════════════════════════╣"
    
    foreach ($region in ($global:regionStats.Keys | Sort-Object)) {
        $regionData = $global:regionStats[$region]
        if ($regionData.Buckets -gt 0) {
            Write-Host ("║ REGION: {0}" -f $region.PadRight(70))
            Write-Host ("║ {0} buckets, {1} objects, {2} total storage" -f 
                $regionData.Buckets, 
                $regionData.Objects, 
                (Format-Size $regionData.Storage))
                
            if ($regionData.StorageByClass.Count -gt 0) {
                Write-Host "║ Storage by class:"
                $regionData.StorageByClass.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object {
                    $class = $_.Key
                    $size = $_.Value
                    $objects = $regionData.ObjectsByClass[$class]
                    $percent = if ($regionData.Storage -gt 0) { ($size / $regionData.Storage * 100) } else { 0 }
                    
                    Write-Host ("║   - {0,-15} {1,10} in {2,10} objects ({3,5:N1}%)" -f 
                        "$($class):",
                        (Format-Size $size).PadLeft(10),
                        $objects.ToString("N0").PadLeft(10),
                        $percent)
                }
            }
            Write-Host "╠══════════════════════════════════════════════════════════════════════════╣"
        }
    }
    Write-Host "╚══════════════════════════════════════════════════════════════════════════╝"
}

Write-Host "`nDetailed bucket information has been saved to: $csvPath"
