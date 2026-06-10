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

$data = Get-FixtureDiscoveryData -FixtureDir $fixtureDir

# Plain assignment: Invoke-DiscoveryEngine returns the result array as a single
# item (comma idiom), so an extra @( ) wrap would nest it.
$selected = Invoke-DiscoveryEngine -Groups $data.Groups -InputData $data.InputData `
    -VendorUsers $data.VendorUsers -DnIndex $data.DnIndex

$summary = [pscustomobject]@{
    TotalGroups   = $selected.Count
    FailedDomains = $data.FailedDomains
    Warnings      = $data.Warnings
    GeneratedAt   = (Get-Date).ToString('u')
}

Write-HtmlReport -Results $selected -Summary $summary -Path $Path
Write-Host ("Wrote {0} group(s) to {1}" -f $selected.Count, $Path)
