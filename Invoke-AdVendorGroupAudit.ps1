<#
.SYNOPSIS
  Runner for the AD Vendor Group Audit. Imports the module and invokes the audit.
.EXAMPLE
  ./Invoke-AdVendorGroupAudit.ps1 -UsersCsv samples/users.csv -DomainsCsv samples/domains.csv `
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
Import-Module (Join-Path $PSScriptRoot 'AdVendorGroupAudit.psd1') -Force
Invoke-AdVendorGroupAudit @PSBoundParameters | Out-Null
