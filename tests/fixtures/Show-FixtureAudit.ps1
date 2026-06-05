<#
.SYNOPSIS
    Demo / smoke-test: runs the engine pipeline over the fixture and prints the
    surfaced groups. Not wired into Pester - run it directly to see the dataset
    exercised end-to-end (no live AD).

.EXAMPLE
    pwsh -NoProfile -File ./tests/fixtures/Show-FixtureAudit.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$fixtureDir = $PSScriptRoot
$testsDir   = Split-Path -Parent $fixtureDir

# Load all engine functions (same mechanism the Pester tests use) + the loader.
. (Join-Path $testsDir '_TestHelpers.ps1')
. (Join-Path $fixtureDir 'Import-AuditFixture.ps1')

$data  = Get-FixtureAuditData -FixtureDir $fixtureDir
$auditInput = $data.InputData

$knownKeys = @{}
foreach ($k in $auditInput.KnownGroups)   { $knownKeys[(Get-GroupLookupKey -Domain $k.Domain -Identity $k.Identity)] = $true }
$excludeKeys = @{}
foreach ($e in $auditInput.ExcludeGroups) { $excludeKeys[(Get-GroupLookupKey -Domain $e.Domain -Identity $e.Identity)] = $true }

$candidates = Find-CandidateGroups -Groups $data.Groups -Keywords $auditInput.Keywords `
    -VendorUsers $data.VendorUsers -KnownKeys $knownKeys -ExcludeKeys $excludeKeys
$candidates = Expand-VendorGroupClosure -Results $candidates
$selected   = Select-AuditResults -Results $candidates
$selected   = Resolve-ResultDisplay -Results $selected -DnIndex $data.DnIndex -VendorUsers $data.VendorUsers

$rank = Get-ConfidenceRank
$selected = @($selected | Sort-Object @{ Expression = { $rank[$_.Confidence] }; Descending = $true }, Domain, Name)

Write-Host ("Audited vendor: Northwind Traders  |  domains={0} users={1} groups-in-directory={2}" -f `
    $auditInput.Domains.Count, $data.VendorUsers.Count, $data.Groups.Count)
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
