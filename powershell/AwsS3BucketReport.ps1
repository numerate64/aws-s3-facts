<#
.SYNOPSIS
Compatibility entry point for the optimized S3 storage report.
#>

[CmdletBinding()]
param(
    [string]$ProfileName,
    [ValidateSet('Fast', 'Exact')]
    [string]$Mode = 'Fast',
    [ValidateRange(1, 64)]
    [int]$Workers = 8,
    [string]$OutputPath = "s3-bucket-report-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv",
    [switch]$RequesterPays,
    [switch]$SkipLargeBuckets,
    [switch]$AllRegions
)

if ($SkipLargeBuckets) {
    Write-Warning '-SkipLargeBuckets is deprecated and ignored.'
}

$scriptPath = Join-Path $PSScriptRoot 'SimpleS3Report.ps1'
& $scriptPath `
    -ProfileName $ProfileName `
    -Mode $Mode `
    -Workers $Workers `
    -OutputPath $OutputPath `
    -RequesterPays:$RequesterPays
