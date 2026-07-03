<#
.SYNOPSIS
    Runs the engine pipeline over the fixture (no live AD) and writes the interactive
    report's sidecar files via Write-JsonReport, plus copies the viewer, so the
    rendered output can be driven in a browser.

.EXAMPLE
    pwsh -NoProfile -File ./tests/fixtures/Export-FixtureJson.ps1 -OutputDirectory ./out
#>
[CmdletBinding()]
param([string]$OutputDirectory = (Join-Path ([System.IO.Path]::GetTempPath()) 'discovery-viewer'))

$ErrorActionPreference = 'Stop'
$fixtureDir = $PSScriptRoot
$testsDir   = Split-Path -Parent $fixtureDir
$root       = Split-Path -Parent $testsDir

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

if (-not (Test-Path -LiteralPath $OutputDirectory)) { New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null }
Write-JsonReport -Results $selected -Summary $summary -OutputDirectory $OutputDirectory
$assetRoot = Join-Path $root 'src/Report/assets'
Copy-Item -LiteralPath (Join-Path $assetRoot 'viewer.html') `
    -Destination (Join-Path $OutputDirectory 'discovery-report.html') -Force
foreach ($asset in 'tabulator.min.js', 'tabulator.min.css') {
    Copy-Item -LiteralPath (Join-Path $assetRoot $asset) -Destination (Join-Path $OutputDirectory $asset) -Force
}
Write-Host ("Wrote interactive report for {0} group(s) to {1}" -f $selected.Count, $OutputDirectory)
