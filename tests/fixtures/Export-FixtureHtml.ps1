<#
.SYNOPSIS
    Runs the engine pipeline over the fixture (no live AD) and writes a real
    HTML report via Write-HtmlReport, so the rendered output can be eyeballed.

.EXAMPLE
    pwsh -NoProfile -File ./tests/fixtures/Export-FixtureHtml.ps1 -Path ./fixture-report.html
#>
[CmdletBinding()]
param([string]$Path = (Join-Path ([System.IO.Path]::GetTempPath()) 'fixture-report.html'))

$ErrorActionPreference = 'Stop'
$fixtureDir = $PSScriptRoot
$testsDir   = Split-Path -Parent $fixtureDir

. (Join-Path $testsDir '_TestHelpers.ps1')
. (Join-Path $fixtureDir 'Import-DiscoveryFixture.ps1')

$data       = Get-FixtureDiscoveryData -FixtureDir $fixtureDir
$discoveryInput = $data.InputData

$knownKeys = @{}
foreach ($k in $discoveryInput.KnownGroups)   { $knownKeys[(Get-GroupLookupKey -Domain $k.Domain -Identity $k.Identity)] = $true }
$excludeKeys = @{}
foreach ($e in $discoveryInput.ExcludeGroups) { $excludeKeys[(Get-GroupLookupKey -Domain $e.Domain -Identity $e.Identity)] = $true }

$candidates = Find-CandidateGroups -Groups $data.Groups -Keywords $discoveryInput.Keywords `
    -VendorUsers $data.VendorUsers -KnownKeys $knownKeys -ExcludeKeys $excludeKeys
$candidates = Expand-VendorGroupClosure -Results $candidates
$selected   = Select-DiscoveryResults -Results $candidates
$selected   = Resolve-ResultDisplay -Results $selected -DnIndex $data.DnIndex -VendorUsers $data.VendorUsers
$selected   = @($selected)

$summary = [pscustomobject]@{
    TotalGroups   = $selected.Count
    FailedDomains = $data.FailedDomains
    Warnings      = $data.Warnings
    GeneratedAt   = (Get-Date).ToString('u')
}

Write-HtmlReport -Results $selected -Summary $summary -Path $Path
Write-Host ("Wrote {0} group(s) to {1}" -f $selected.Count, $Path)
