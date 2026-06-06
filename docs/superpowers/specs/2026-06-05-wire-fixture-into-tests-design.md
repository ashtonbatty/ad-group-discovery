# Wire the Discovery Fixture into Integration Tests — Design

**Date:** 2026-06-05
**Status:** Approved (brainstorming complete; ready for implementation plan)

## Purpose

The repository now contains a rich, deterministic, multi-domain test fixture under
`tests/fixtures/` (4 domains, 40 users, 20 groups, two directory structures, with a
documented expected-results oracle in `tests/fixtures/README.md`). Today nothing in
the Pester suite consumes it. This work adds fixture-backed **integration tests**
that exercise the engine over realistic data and lock in the documented behaviour.

## Scope

- **In scope:** one new Pester file, `tests/Fixture.Tests.ps1`, with two `Describe`
  blocks (engine pipeline + public function), asserting the fixture's oracle exactly.
- **Out of scope:** the 20 existing focused unit tests stay exactly as they are. No
  source-code changes. No changes to the fixture data, generator, loader, or README.
  The existing minimal `Find-VendorAdGroup.Tests.ps1` smoke test stays.

## Approach

A single cohesive file (`tests/Fixture.Tests.ps1`) so the fixture is loaded once and
a single hand-authored oracle is shared by both `Describe` blocks. The oracle is
**authored independently** of the engine (transcribed from the README), not generated
by running the code under test — otherwise the assertions would be circular.

## Setup (`BeforeAll`)

```powershell
. "$PSScriptRoot/_TestHelpers.ps1"                       # loads engine functions + AD stubs
. "$PSScriptRoot/fixtures/Import-DiscoveryFixture.ps1"       # Get-FixtureDiscoveryData
$script:fixtureDir = Join-Path $PSScriptRoot 'fixtures'
$script:data  = Get-FixtureDiscoveryData -FixtureDir $fixtureDir
```

The hand-authored oracle (kept in sync with `tests/fixtures/README.md`):

| Expected band | Groups |
|---|---|
| Confirmed | Project Atlas Team |
| High | Northwind Traders Admins, NWT Application Owners, Northwind Support, NWT Finance Sync, Logistics Integration RW, Traders Data Feed, APAC Vendor Access, Northwind RW |
| Medium | Global Logistics Stewards |
| Absent (decoys) | Contoso Service Desk, Contoso Billing Admins, Contoso EDI Integration, Fabrikam Plant Ops, Fabrikam QA Team, Fabrikam Sensor Net, Globex IT Admins, Globex Helpdesk |
| Absent (excluded) | All Staff, Globex All Employees |

Represented in the test as a `$script:expectedBand` hashtable (Name → band) plus a
`$script:absent` array. Total surfaced = 10.

## Describe 1 — engine pipeline

Build the result set once in this block:

```powershell
$input = $data.InputData
$knownKeys   = @{}; foreach ($k in $input.KnownGroups)   { $knownKeys[(Get-GroupLookupKey -Domain $k.Domain -Identity $k.Identity)] = $true }
$excludeKeys = @{}; foreach ($e in $input.ExcludeGroups) { $excludeKeys[(Get-GroupLookupKey -Domain $e.Domain -Identity $e.Identity)] = $true }
$cand = Find-CandidateGroups -Groups $data.Groups -Keywords $input.Keywords -VendorUsers $data.VendorUsers -KnownKeys $knownKeys -ExcludeKeys $excludeKeys
$cand = Expand-VendorGroupClosure -Results $cand
$sel  = Select-DiscoveryResults -Results $cand
$sel  = Resolve-ResultDisplay -Results $sel -DnIndex $data.DnIndex -VendorUsers $data.VendorUsers
$byName = @{}; foreach ($r in $sel) { $byName[$r.Name] = $r }
```

`It` blocks (exact oracle):

1. **Surfaces exactly the expected 10 groups** — `$sel.Name | Sort-Object` equals the
   sorted oracle name set; `$sel.Count -eq 10`.
2. **Each surfaced group's band matches the oracle** — loop the oracle map:
   `$byName[$name].Confidence | Should -Be $expectedBand[$name]`.
3. **Closure** — `Global Logistics Stewards` has a reason with `Pattern='NestedVendorGroup'`
   and `Confidence='Medium'`.
4. **Known** — `Project Atlas Team` has `Confidence='Confirmed'` and `Source='Known'`.
5. **Cross-domain foreign-SID member** — `NWT Application Owners` has a reason
   `Pattern='MemberVendorUser'` with `Value='Omar Haddad'` (the FSP SID resolved to a
   Northwind user from another domain).
6. **Description-mentions-user** — `Logistics Integration RW` has a reason
   `Pattern='DescriptionUser'` (value references `jbrooks`).
7. **Precision** — each decoy name in `$absent` is **not** in `$sel.Name`.
8. **Vendor-member flag** — `Northwind Traders Admins`' `Members` contains an entry
   matching `*Maria Hale` (leading `*` marks a vendor member).
9. **`-MinimumConfidence High`** — `Select-DiscoveryResults -Results $cand -MinimumConfidence 'High'`
   excludes `Global Logistics Stewards` (Medium), includes `Project Atlas Team`
   (Confirmed), and yields 9 results.
10. **`-SecurityGroupsOnly` filter** — applying the same `GroupCategory -eq 'Security'`
    filter the orchestrator uses, before matching, drops `Northwind Support`
    (Distribution) → 9 surfaced; the other surfaced groups are unchanged.

## Describe 2 — public path (`Find-VendorAdGroup`)

```powershell
BeforeAll {
    $script:outDir = Join-Path ([IO.Path]::GetTempPath()) ("fx_" + [guid]::NewGuid())
    Mock -CommandName Get-AdDiscoveryData -MockWith {
        $d = Get-FixtureDiscoveryData -FixtureDir $fixtureDir
        [pscustomobject]@{ Groups=$d.Groups; VendorUsers=$d.VendorUsers; DnIndex=$d.DnIndex; FailedDomains=@(); Warnings=@() }
    }
    $inDir = Join-Path $fixtureDir 'discovery-input'
    Find-VendorAdGroup -UsersCsv "$inDir/users.csv" -DomainsCsv "$inDir/domains.csv" `
        -KeywordsCsv "$inDir/keywords.csv" -KnownGroupsCsv "$inDir/known.csv" `
        -ExcludeGroupsCsv "$inDir/exclude.csv" -OutputDirectory $outDir -Formats @('Csv','Html')
}
AfterAll { Remove-Item -Recurse -Force $script:outDir -ErrorAction SilentlyContinue }
```

`It` blocks:

1. **CSV row count = 10** (`Import-Csv vendor-group-discovery.csv`).
2. **Closure reason in CSV** — the `Global Logistics Stewards` row's `MatchReasons`
   contains `NestedVendorGroup`.
3. **Known band in CSV** — the `Project Atlas Team` row has `Confidence='Confirmed'`.
4. **Precision in CSV** — no row named `Contoso Service Desk`.
5. **Vendor-member flag in CSV** — the `Northwind Traders Admins` row's `Members`
   contains `*Maria Hale`.
6. **HTML written and populated** — `vendor-group-discovery.html` exists, contains
   `Northwind Traders Admins`, and contains an `<h2>` domain header for each of the
   four domains that have results (`corp.globex.com`, `emea.globex.com`,
   `apac.globex.local`, `dmz.globex.net`).

Console output is already covered by `Write-ConsoleSummary.Tests.ps1`, so the public
test requests only `Csv,Html`.

## Error handling

Pure test code. The temp output directory is created by `Find-VendorAdGroup`
and removed in `AfterAll`. No global state is mutated; the `Get-AdDiscoveryData` mock is
scoped to Describe 2.

## Testing / success criteria

- New file `tests/Fixture.Tests.ps1` adds ~16 `It` assertions; the full suite grows
  from 62 to ~78 and stays green.
- PSScriptAnalyzer remains clean project-wide (the file must avoid `$input` as a
  variable name — use `$discoveryInput` — since `$input` is an automatic variable).
- If the oracle in this test and `tests/fixtures/README.md` ever disagree with the
  engine, the test fails — that is the intended signal.

## YAGNI / out of scope

- No refactor of existing unit tests to draw from the fixture.
- No generated/expected-results data file (oracle is hand-authored in the test).
- No console-capture assertions in the public test (covered elsewhere).
