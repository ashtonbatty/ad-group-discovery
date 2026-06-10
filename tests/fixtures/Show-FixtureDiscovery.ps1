<#
.SYNOPSIS
    Demo / smoke-test: runs the engine pipeline over the fixture and prints the
    surfaced groups. Not wired into Pester - run it directly to see the dataset
    exercised end-to-end (no live AD).

.EXAMPLE
    pwsh -NoProfile -File ./tests/fixtures/Show-FixtureDiscovery.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$fixtureDir = $PSScriptRoot
$testsDir   = Split-Path -Parent $fixtureDir

# Load all engine functions (same mechanism the Pester tests use) + the loader.
. (Join-Path $testsDir '_TestHelpers.ps1')
. (Join-Path $fixtureDir 'Import-DiscoveryFixture.ps1')

$data  = Get-FixtureDiscoveryData -FixtureDir $fixtureDir
$discoveryInput = $data.InputData

$selected = Invoke-DiscoveryEngine -Groups $data.Groups -InputData $discoveryInput `
    -VendorUsers $data.VendorUsers -DnIndex $data.DnIndex

Write-Host ("Discovered vendor: Northwind Traders  |  domains={0} users={1} groups-in-directory={2}" -f `
    $discoveryInput.Domains.Count, $data.VendorUsers.Count, $data.Groups.Count)
Write-Host ("Surfaced {0} group(s):`n" -f $selected.Count)
Write-Host ("{0,-10} {1,-6} {2,-26} {3}" -f 'BAND','SCORE','GROUP','REASONS')
Write-Host ('-' * 100)
foreach ($r in $selected) {
    $reasons = (@($r.Reasons) | ForEach-Object { "$($_.Pattern)" } | Sort-Object -Unique) -join ','
    Write-Host ("{0,-10} {1,-6} {2,-26} {3}" -f $r.Confidence, $r.Score, $r.Name, $reasons)
}
Write-Host ''
Write-Host 'Security groups only (-SecurityGroupsOnly drops distribution groups):'
$secOnly = @($selected | Where-Object { $_.GroupCategory -eq 'Security' })
Write-Host ("  {0} of {1} surfaced groups are security groups" -f $secOnly.Count, $selected.Count)
