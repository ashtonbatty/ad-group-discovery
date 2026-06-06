<#
.SYNOPSIS
  Runner for the Vendor AD Group Discovery. Imports the module and invokes the discovery.
.EXAMPLE
  ./Find-VendorAdGroup.ps1 -UsersCsv samples/users.csv -DomainsCsv samples/domains.csv `
    -KeywordsCsv samples/keywords.csv -KnownGroupsCsv samples/known.csv `
    -ExcludeGroupsCsv samples/exclude.csv -OutputDirectory ./out
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$UsersCsv,
    [Parameter(Mandatory)][string]$DomainsCsv,
    [Parameter(Mandatory)][string]$KeywordsCsv,
    [Parameter(Mandatory)][string]$KnownGroupsCsv,
    [Parameter(Mandatory)][string]$ExcludeGroupsCsv,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [ValidateSet('Csv','Html','Console')][string[]]$Formats = @('Csv','Html','Console'),
    [System.Management.Automation.PSCredential]$Credential,
    [int]$MaxIterations = 25,
    [switch]$SecurityGroupsOnly,
    [ValidateSet('Low','Medium','High','Confirmed')][string]$MinimumConfidence = 'Low'
)
Import-Module (Join-Path $PSScriptRoot 'VendorAdGroupDiscovery.psd1') -Force
Find-VendorAdGroup @PSBoundParameters | Out-Null
