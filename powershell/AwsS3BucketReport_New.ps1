<#
.SYNOPSIS
Compatibility entry point for the optimized S3 storage report.
#>

[CmdletBinding()]
param(
    [string]$ProfileName,
    [ValidateRange(1, 64)]
    [int]$Workers = 8,
    [string]$OutputPath = "s3-bucket-report-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv",
    [switch]$RequesterPays,
    [switch]$SkipLargeBuckets,
    [switch]$AllRegions
)

if ($SkipLargeBuckets) {
    Write-Warning '-SkipLargeBuckets is deprecated and ignored because an exact report requires every object.'
}

$scriptPath = Join-Path $PSScriptRoot 'SimpleS3Report.ps1'
& $scriptPath `
    -ProfileName $ProfileName `
    -Workers $Workers `
    -OutputPath $OutputPath `
    -RequesterPays:$RequesterPays
