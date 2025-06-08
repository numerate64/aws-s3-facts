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

# Define parameters with proper syntax
param(
    [string]$ProfileName = "default",
    [switch]$SkipLargeBuckets,
    [switch]$AllRegions
)

# Set default values
if (-not $PSBoundParameters.ContainsKey('AllRegions')) { $AllRegions = $true }
if (-not $PSBoundParameters.ContainsKey('SkipLargeBuckets')) { $SkipLargeBuckets = $false }
if ([string]::IsNullOrEmpty($ProfileName)) { $ProfileName = "default" }

# Set default profile if not provided
if ([string]::IsNullOrEmpty($ProfileName)) {
    $ProfileName = "TempSession"
}

# Initialize AWS configuration
try {
    # Use default credentials from AWS CLI configuration
    Write-Host "Using default AWS credentials"
    
    # Set default region
    $region = 'us-east-1'  # Default to us-east-1 if not set
    if (Get-Command Get-DefaultAWSRegion -ErrorAction SilentlyContinue) {
        $currentRegion = Get-DefaultAWSRegion -ErrorAction SilentlyContinue
        if ($currentRegion) { $region = $currentRegion.Region }
    }
    
    # Set AWS region
    if (Get-Command Set-DefaultAWSRegion -ErrorAction SilentlyContinue) {
        Set-DefaultAWSRegion -Region $region -Scope Script -ErrorAction SilentlyContinue
    }
    
    Write-Host "Using AWS region: $region"
    
    # Test AWS credentials
    try {
        $caller = Get-STSCallerIdentity -ErrorAction Stop
        Write-Host "Successfully authenticated as: $($caller.Arn)"
    } catch {
        Write-Warning "Could not verify AWS credentials. Some operations may fail."
        Write-Warning "Error: $($_.Exception.Message)"
    }
    
} catch {
    Write-Error "Failed to initialize AWS: $_"
    Write-Error "Please ensure you have valid AWS credentials configured in ~/.aws/credentials"
    exit 1
}

# Set default region if not specified
if (-not $Regions -or $Regions.Count -eq 0) {
    $Regions = @('us-east-1')
}

# Set max objects to a very high number if not skipping large buckets
$maxObjects = if ($SkipLargeBuckets) { 1000 } else { [int]::MaxValue }

# Function to get AWS regions
function Get-AWSRegions {
    [CmdletBinding()]
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
    [CmdletBinding()]
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

# Initialize global variables
$allResults = @()
$global:regionStats = @{}

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
    Write-Host "`n=== Processing region: $Region ===" -ForegroundColor Cyan
    
    try {
        Write-Host "`nFetching buckets for region: $Region"
        
        # Get all buckets (this lists all buckets, but we'll filter by region)
        $allBuckets = Get-S3Bucket -Region $Region -ErrorAction Stop
        Write-Host "Found $($allBuckets.Count) total buckets in account"
        
        # Filter buckets by region
        $bucketsInRegion = @()
        $bucketCount = 0
        
        foreach ($bucket in $allBuckets) {
            $bucketCount++
            Write-Progress -Activity "Checking bucket regions" -Status "Processing bucket $bucketCount of $($allBuckets.Count)" -PercentComplete (($bucketCount / $allBuckets.Count) * 100)
            
            try {
                # Get bucket location
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
                
                # Get bucket objects with pagination
                $objectCount = 0
                $totalSize = 0
                $nextToken = $null
                $isTruncated = $false
                $objects = @()
                
                do {
                    $requestCount++
                    try {
                        # Get objects from S3 with pagination
                        $params = @{
                            BucketName = $bucketName
                            Region = $bucketRegion
                            ErrorAction = 'Stop'
                            MaxKeys = 1000  # Maximum allowed by S3 API
                        }
                        
                        if ($nextToken) {
                            $params['ContinuationToken'] = $nextToken
                        }
                        
                        Write-Host "  Sending request to Get-S3Object with params:"
                        $params | Format-Table -AutoSize | Out-String | ForEach-Object { Write-Host "    $_" }
                        
                        try {
                            $response = Get-S3Object @params -ErrorAction Stop
                            $isTruncated = $response.IsTruncated
                            $nextToken = $response.NextContinuationToken
                            
                            Write-Host "  Response received. IsTruncated: $isTruncated, HasNextToken: $($null -ne $nextToken)"
                            
                            if ($response.Contents) {
                                Write-Host "  Found $($response.Contents.Count) objects in response"
                                # Print first few objects for debugging
                                $response.Contents | Select-Object -First 3 | ForEach-Object {
                                    Write-Host "    - $($_.Key) (Size: $($_.Size) bytes, Class: $($_.StorageClass))"
                                }
                                if ($response.Contents.Count -gt 3) {
                                    Write-Host "    ... and $($response.Contents.Count - 3) more objects"
                                }
                            } else {
                                Write-Host "  No objects found in this response"
                            }
                        } catch {
                            Write-Host "  Error listing objects in bucket $bucketName : $_" -ForegroundColor Red
                            Write-Host $_.ScriptStackTrace -ForegroundColor DarkRed
                            $isTruncated = $false
                            $errorDetails = $_.Exception.Message
                            if ($errorDetails -like "*Access Denied*" -or $errorDetails -like "*Forbidden*") {
                                Write-Host "  You don't have permission to list objects in this bucket" -ForegroundColor Yellow
                            } elseif ($errorDetails -like "*NoSuchBucket*") {
                                Write-Host "  Bucket does not exist or you don't have permission to access it" -ForegroundColor Yellow
                            }
                            continue
                        }
                        
                        if ($response.Contents) {
                            $batchSize = $response.Contents.Count
                            $objectCount += $batchSize
                            $processedObjects = 0  # Reset processed objects counter for this batch
                            
                            try {
                                foreach ($obj in $response.Contents) {
                                    $objSize = $obj.Size
                                    $totalSize += $objSize
                                    $processedObjects++
                                    
                                    # Track storage class with standardization and error handling
                                    $class = 'STANDARD'  # Default value
                                    
                                    # Standardize storage class with error handling
                                    try {
                                        if ($obj.StorageClass) { 
                                            $classValue = $obj.StorageClass.ToString().Trim().ToUpper()
                                            # Standardize storage class names
                                            $class = switch -Wildcard ($classValue) {
                                                'STANDARD*' { 'STANDARD' }
                                                'STANDARD_IA*' { 'STANDARD_IA' }
                                                'INTELLIGENT_TIERING*' { 'INTELLIGENT_TIERING' }
                                                'GLACIER*' { 'GLACIER' }
                                                'DEEP_ARCHIVE*' { 'DEEP_ARCHIVE' }
                                                'GLACIER_IR*' { 'GLACIER_IR' }
                                                'ONEZONE_IA*' { 'ONEZONE_IA' }
                                                'REDUCED_REDUNDANCY*' { 'REDUCED_REDUNDANCY' }
                                                'OUTPOSTS*' { 'OUTPOSTS' }
                                                default { 
                                                    if ($null -eq $classValue) { 'STANDARD' } 
                                                    else { $classValue.ToString().ToUpper() } 
                                                }
                                            }
                                        } else {
                                            $class = 'STANDARD'
                                        }
                                    } catch {
                                        $class = 'STANDARD'
                                    }
                                    
                                    if (-not $storageByClass.ContainsKey($class)) {
                                        $storageByClass[$class] = 0
                                    }
                                    $storageByClass[$class] += $objSize
                                    
                                    # Only add to objects array if we're not skipping large buckets
                                    if (-not $SkipLargeBuckets -or $objectCount -le $maxObjects) {
                                        $objects += $obj
                                        Write-Verbose "  Added object: $($obj.Key) (Size: $($obj.Size) bytes, Class: $class)"
                                    }
                                }
                                
                                # Update progress after processing batch
                                $elapsed = (Get-Date) - $startTime
                                $rate = if ($elapsed.TotalSeconds -gt 0) { [math]::Round($processedObjects / $elapsed.TotalSeconds, 2) } else { 0 }
                                $status = "Fetched $objectCount objects (${processedObjects} in batch) | ${rate} obj/sec | $(Format-Size $totalSize)"
                                $percentComplete = [math]::Min(($objectCount / $maxObjects) * 100, 100)
                                Write-Progress -Activity "Processing $bucketName" -Status $status -PercentComplete $percentComplete
                                
                                # Check if we've reached the maximum objects to process
                                if ($objectCount -ge $maxObjects) {
                                    if ($SkipLargeBuckets) {
                                        Write-Warning "  Reached maximum object limit of $maxObjects for bucket $bucketName. Skipping remaining objects."
                                        $isTruncated = $false  # Stop pagination
                                        break
                                    } else {
                                        Write-Verbose "  Reached maximum object limit of $maxObjects for bucket $bucketName. Continuing with partial results."
                                    }
                                }
                                
                                # Add a small delay to avoid throttling
                                if ($isTruncated) {
                                    Start-Sleep -Milliseconds 200
                                }
                                
                            } catch {
                                Write-Error "Error processing object in $bucketName : $_"
                                # Continue with next object even if one fails
                                continue
                            }
                        }
                    } catch [Amazon.S3.AmazonS3Exception] {
                        $errorMsg = $_.Exception.Message
                        if ($errorMsg -like "*AccessDenied*" -or $errorMsg -like "*Forbidden*") {
                            Write-Warning "  Access denied to list objects in bucket $bucketName"
                            $isTruncated = $false  # Stop pagination
                            break
                        } else {
                            Write-Error "Error listing objects in bucket $bucketName : $_"
                            $isTruncated = $false  # Stop pagination on error
                            break
                        }
                    } catch {
                        Write-Error "Unexpected error listing objects in bucket $bucketName : $_"
                        $isTruncated = $false  # Stop pagination on error
                        break
                    }
                } while ($isTruncated -and $objectCount -lt $maxObjects)
                
                # Clear progress when done
                Write-Progress -Activity "Processing $bucketName" -Completed
                
                # Add bucket results to region stats if we have data
                if (($totalSize -gt 0 -or $objectCount -gt 0) -and $storageByClass.Count -gt 0) {
                    if (-not $global:regionStats.ContainsKey($Region)) {
                        $global:regionStats[$Region] = @{
                            Buckets = 0
                            Objects = 0
                            Storage = 0
                            StorageByClass = @{}
                            ObjectsByClass = @{}
                        }
                    }
                    
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
                        $global:regionStats[$Region].ObjectsByClass[$class] += ($objects | Where-Object { 
                            $objClass = if ($_.StorageClass) { $_.StorageClass.ToString().ToUpper() } else { 'STANDARD' }
                            $objClass -eq $class
                        }).Count
                    }
                }
                
                Write-Host "    Found $objectCount objects in bucket $bucketName (Total size: $(Format-Size $totalSize))"
                
                # Initialize storage summary for this bucket
                # Create storage summary
                $storageSummary = [ordered]@{}
                $bucketSize = $totalSize
                $bucketObjects = $objectCount
                
                # Update region stats and storage by class
                if ($totalSize -gt 0) {
                    $global:regionStats[$Region].Buckets++
                    $global:regionStats[$Region].Objects += $objectCount
                    $global:regionStats[$Region].Storage += $totalSize
                    
                    foreach ($class in $storageByClass.Keys) {
                        if (-not $global:regionStats[$Region].StorageByClass.ContainsKey($class)) {
                            $global:regionStats[$Region].StorageByClass[$class] = 0
                            $global:regionStats[$Region].ObjectsByClass[$class] = 0
                        }
                        $global:regionStats[$Region].StorageByClass[$class] += $storageByClass[$class]
                        $global:regionStats[$Region].ObjectsByClass[$class] += ($objects | Where-Object { 
                            $objClass = if ($_.StorageClass) { $_.StorageClass.ToString().ToUpper() } else { 'STANDARD' }
                            $objClass -eq $class
                        }).Count
                    }
                }
                
                # Create result object for this bucket with all properties
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
                    Timestamp = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
                }
                
                Write-Host "    Processing $objectCount objects..."
                
                # Initialize storage class tracking for this bucket
                $bucketStorageByClass = @{}
                
                # Initialize global storage classes tracking if not already done
                if (-not $script:allStorageClasses) {
                    $script:allStorageClasses = @{}
                    $script:totalStorageByClass = @{}
                    $script:totalObjectsByClass = @{}
                    $script:storageClassesInitialized = $true
                }
                
                # Calculate storage by class if we have objects
                if ($objects -and $objects.Count -gt 0) {
                    try {
                        foreach ($obj in $objects) {
                            # Standardize storage class name
                            try {
                                $storageClass = if ($obj.StorageClass) { 
                                    $obj.StorageClass.ToString().ToUpper() 
                                } else { 
                                    'STANDARD' 
                                }
                                
                                # Initialize storage class tracking if it doesn't exist
                                if (-not $bucketStorageByClass.ContainsKey($storageClass)) {
                                    $bucketStorageByClass[$storageClass] = @{
                                        Size = 0
                                        Count = 0
                                    }
                                    
                                    # Track all unique storage classes globally
                                    if (-not $script:allStorageClasses.ContainsKey($storageClass)) {
                                        $script:allStorageClasses[$storageClass] = $true
                                        $script:totalStorageByClass[$storageClass] = 0
                                        $script:totalObjectsByClass[$storageClass] = 0
                                    }
                                }
                                
                                # Update storage class metrics
                                $bucketStorageByClass[$storageClass].Size += $obj.Size
                                $bucketStorageByClass[$storageClass].Count++
                                $bucketSize += $obj.Size
                                $bucketObjects++
                            } catch {
                                Write-Warning "Error processing object in bucket $bucketName : $_"
                                continue
                            }
                        }
                    } catch {
                        Write-Error "Error processing objects for bucket $bucketName : $_"
                        continue
                    }
                }
                
                # Storage classes tracking is now initialized at the beginning of the script
                
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
                            $script:totalStorageByClass[$class] = 0
                            $script:totalObjectsByClass[$class] = 0
                        }
                        
                        # Update global totals
                        $script:totalStorageByClass[$class] += $bucketStorageByClass[$class].Size
                        $script:totalObjectsByClass[$class] += $bucketStorageByClass[$class].Count
                        
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
                try {
                    if ($null -ne $script:allStorageClasses -and $script:allStorageClasses.Count -gt 0) {
                        $storageClassList = $script:allStorageClasses.Keys | Sort-Object
                        
                        foreach ($storageClass in $storageClassList) {
                            # Get size and count for this storage class
                            $size = if ($bucketStorageByClass.ContainsKey($storageClass)) { 
                                $bucketStorageByClass[$storageClass].Size 
                            } else { 
                                0 
                            }
                            
                            $count = if ($bucketStorageByClass.ContainsKey($storageClass)) { 
                                $bucketStorageByClass[$storageClass].Count 
                            } else { 
                                0 
                            }
                            
                            # Initialize region stats for this storage class if needed
                            if (-not $global:regionStats[$Region].StorageByClass.ContainsKey($storageClass)) {
                                $global:regionStats[$Region].StorageByClass[$storageClass] = 0
                                $global:regionStats[$Region].ObjectsByClass[$storageClass] = 0
                            }
                            
                            # Update region stats
                            $global:regionStats[$Region].StorageByClass[$storageClass] += $size
                            $global:regionStats[$Region].ObjectsByClass[$storageClass] += $count
                            
                            # Update global totals
                            $totalStorageByClass[$storageClass] += $size
                            $totalObjectsByClass[$storageClass] += $count
                        }
                    }
                } catch {
                    Write-Error "Error updating region stats for bucket $bucketName : $_"
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

# Clean up any remaining progress bars
Write-Progress -Activity "Completed" -Completed
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
