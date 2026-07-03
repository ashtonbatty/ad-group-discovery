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
    # Only bound parameters are forwarded; defaults are owned by the module's
    # Find-VendorAdGroup function - do not duplicate them here.
    [Parameter(Mandatory)][string]$UsersCsv,
    [Parameter(Mandatory)][string]$DomainsCsv,
    [Parameter(Mandatory)][string]$KeywordsCsv,
    [Parameter(Mandatory)][string]$KnownGroupsCsv,
    [Parameter(Mandatory)][string]$ExcludeGroupsCsv,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [ValidateSet('Csv','Html','Console','Json')][string[]]$Formats,
    [System.Management.Automation.PSCredential]$Credential,
    [hashtable]$DomainCredentials,
    [switch]$SecurityGroupsOnly,
    [ValidateSet('Low','Medium','High','Confirmed')][string]$MinimumConfidence
)
Import-Module (Join-Path $PSScriptRoot 'VendorAdGroupDiscovery.psd1') -Force
Find-VendorAdGroup @PSBoundParameters | Out-Null
