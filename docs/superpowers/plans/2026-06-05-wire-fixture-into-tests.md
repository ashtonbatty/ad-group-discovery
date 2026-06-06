# Wire the Discovery Fixture into Integration Tests — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a fixture-backed integration test file (`tests/Fixture.Tests.ps1`) that drives the engine pipeline and the public `Find-VendorAdGroup` over the realistic multi-domain fixture, asserting the documented result oracle exactly.

**Architecture:** One new Pester 5 file with two `Describe` blocks. A top-level `BeforeAll` loads the engine functions and the fixture loader and defines a hand-authored oracle. Describe 1 runs `Find-CandidateGroups → Expand-VendorGroupClosure → Select-DiscoveryResults → Resolve-ResultDisplay` over the fixture; Describe 2 mocks `Get-AdDiscoveryData` to return the fixture and runs the public function, asserting the CSV/HTML reports. These are characterization/integration tests over already-working code, so each new assertion is expected to PASS immediately; a failure means the oracle or the engine drifted.

**Tech Stack:** Windows PowerShell 5.1 target (tests run under pwsh 7.6), Pester 5.7, PSScriptAnalyzer.

---

## Conventions

- Run a single file: `pwsh -NoProfile -Command "Invoke-Pester -Path ./tests/Fixture.Tests.ps1 -Output Detailed"`.
- Run the whole suite: `pwsh -NoProfile -Command "Invoke-Pester -Path ./tests -Output Detailed"`.
- **Do NOT name any variable `$input`** — it is a PowerShell automatic variable and PSScriptAnalyzer flags it. Use `$discoveryInput`.
- Cross-`Describe`/`It` variables set in a `BeforeAll` must use the `$script:` scope to be visible in `It` blocks (Pester 5 scoping).
- Work from `/var/home/ashton/dev/misc/powershell/ad-group-discovery`. The git repo root is the working directory. ONLY `git add` the file(s) listed per task — never `git add .` / `-A`.
- End each commit message body with: `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.

## Fixture facts the assertions rely on (already verified by `tests/fixtures/Show-FixtureDiscovery.ps1`)

Discovering **Northwind Traders** surfaces exactly these 10 groups:

| Group | Band | Domain |
|---|---|---|
| Project Atlas Team | Confirmed | corp.globex.com |
| Northwind Traders Admins | High | corp.globex.com |
| NWT Application Owners | High | corp.globex.com |
| Logistics Integration RW | High | corp.globex.com |
| Global Logistics Stewards | Medium | corp.globex.com |
| Northwind Support | High (Distribution) | emea.globex.com |
| NWT Finance Sync | High | emea.globex.com |
| Traders Data Feed | High | apac.globex.local |
| APAC Vendor Access | High | apac.globex.local |
| Northwind RW | High | dmz.globex.net |

Decoys/excluded that must NOT surface: Contoso Service Desk, Contoso Billing Admins,
Contoso EDI Integration, Fabrikam Plant Ops, Fabrikam QA Team, Fabrikam Sensor Net,
Globex IT Admins, Globex Helpdesk, All Staff, Globex All Employees.

Specific facts:
- `NWT Application Owners` has a `MemberVendorUser` reason with `Value='Omar Haddad'` (a member referenced as a foreign-security-principal SID from another domain, resolved cross-domain).
- `Logistics Integration RW` has a `DescriptionUser` reason whose `Value` contains `jbrooks`.
- `Northwind Traders Admins`' resolved `Members` contains `*Maria Hale` (the `*` marks a vendor member).
- `Global Logistics Stewards` has only a `NestedVendorGroup` reason (closure).
- `Project Atlas Team` has `Source='Known'`.

---

## Task 1: Scaffold the file — setup, oracle, and the exact-10 assertion

**Files:**
- Create: `tests/Fixture.Tests.ps1`

- [ ] **Step 1: Create the file with the top-level setup, the oracle, the Describe-1 pipeline setup, and the first assertion**

```powershell
BeforeAll {
    . "$PSScriptRoot/_TestHelpers.ps1"
    . "$PSScriptRoot/fixtures/Import-DiscoveryFixture.ps1"
    $script:fixtureDir = Join-Path $PSScriptRoot 'fixtures'
    $script:data       = Get-FixtureDiscoveryData -FixtureDir $script:fixtureDir

    # Hand-authored oracle (kept in sync with tests/fixtures/README.md).
    $script:expectedBand = @{
        'Project Atlas Team'        = 'Confirmed'
        'Northwind Traders Admins'  = 'High'
        'NWT Application Owners'    = 'High'
        'Northwind Support'         = 'High'
        'NWT Finance Sync'          = 'High'
        'Logistics Integration RW'  = 'High'
        'Traders Data Feed'         = 'High'
        'APAC Vendor Access'        = 'High'
        'Northwind RW'              = 'High'
        'Global Logistics Stewards' = 'Medium'
    }
    $script:absent = @(
        'Contoso Service Desk','Contoso Billing Admins','Contoso EDI Integration',
        'Fabrikam Plant Ops','Fabrikam QA Team','Fabrikam Sensor Net',
        'Globex IT Admins','Globex Helpdesk','All Staff','Globex All Employees'
    )
}

Describe 'Fixture: engine pipeline (Northwind discovery)' {
    BeforeAll {
        $discoveryInput = $script:data.InputData
        $knownKeys = @{}
        foreach ($k in $discoveryInput.KnownGroups)   { $knownKeys[(Get-GroupLookupKey -Domain $k.Domain -Identity $k.Identity)] = $true }
        $excludeKeys = @{}
        foreach ($e in $discoveryInput.ExcludeGroups) { $excludeKeys[(Get-GroupLookupKey -Domain $e.Domain -Identity $e.Identity)] = $true }

        $cand = Find-CandidateGroups -Groups $script:data.Groups -Keywords $discoveryInput.Keywords `
            -VendorUsers $script:data.VendorUsers -KnownKeys $knownKeys -ExcludeKeys $excludeKeys
        $cand = Expand-VendorGroupClosure -Results $cand
        $sel  = Select-DiscoveryResults -Results $cand
        $sel  = Resolve-ResultDisplay -Results $sel -DnIndex $script:data.DnIndex -VendorUsers $script:data.VendorUsers

        $script:cand = $cand
        $script:sel  = $sel
        $script:byName = @{}
        foreach ($r in $sel) { $script:byName[$r.Name] = $r }
    }

    It 'surfaces exactly the 10 expected groups' {
        $expected = @($script:expectedBand.Keys | Sort-Object)
        $actual   = @($script:sel.Name | Sort-Object)
        $actual | Should -Be $expected
    }
}
```

- [ ] **Step 2: Run the file and confirm the assertion passes**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path ./tests/Fixture.Tests.ps1 -Output Detailed"`
Expected: 1 test, PASS. (If it fails, the engine result set differs from the oracle — stop and investigate, do not loosen the assertion.)

- [ ] **Step 3: Commit**

```bash
git add tests/Fixture.Tests.ps1
git commit -m "test: scaffold fixture integration test with exact-set assertion

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 2: Describe 1 — band + behavioral assertions

**Files:**
- Modify: `tests/Fixture.Tests.ps1`

- [ ] **Step 1: Add these `It` blocks inside `Describe 'Fixture: engine pipeline (Northwind discovery)'`, immediately after the existing "surfaces exactly the 10 expected groups" test and before the Describe's closing `}`**

```powershell
    It 'assigns each surfaced group its expected confidence band' {
        foreach ($name in $script:expectedBand.Keys) {
            $script:byName[$name].Confidence | Should -Be $script:expectedBand[$name] -Because "band for '$name'"
        }
    }

    It 'promotes Global Logistics Stewards to Medium via nested-group closure' {
        $g = $script:byName['Global Logistics Stewards']
        $g.Confidence | Should -Be 'Medium'
        @($g.Reasons | Where-Object { $_.Pattern -eq 'NestedVendorGroup' }).Count | Should -BeGreaterThan 0
    }

    It 'marks the known group Confirmed with Source=Known' {
        $g = $script:byName['Project Atlas Team']
        $g.Confidence | Should -Be 'Confirmed'
        $g.Source     | Should -Be 'Known'
    }

    It 'resolves a cross-domain foreign-SID member to a vendor user' {
        $g = $script:byName['NWT Application Owners']
        $values = @($g.Reasons | Where-Object { $_.Pattern -eq 'MemberVendorUser' } | ForEach-Object { $_.Value })
        $values | Should -Contain 'Omar Haddad'
    }

    It 'matches a vendor user mentioned in a group description' {
        $g = $script:byName['Logistics Integration RW']
        $du = @($g.Reasons | Where-Object { $_.Pattern -eq 'DescriptionUser' })
        $du.Count | Should -BeGreaterThan 0
        ($du | ForEach-Object { $_.Value }) -join ' ' | Should -Match 'jbrooks'
    }

    It 'flags vendor members with a leading asterisk in the resolved member list' {
        $g = $script:byName['Northwind Traders Admins']
        $g.Members | Should -Contain '*Maria Hale'
    }

    It 'does not surface any decoy or excluded group' {
        foreach ($name in $script:absent) {
            $script:sel.Name | Should -Not -Contain $name -Because "'$name' must not surface"
        }
    }
```

- [ ] **Step 2: Run the file and confirm all assertions pass**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path ./tests/Fixture.Tests.ps1 -Output Detailed"`
Expected: 8 tests, all PASS.

- [ ] **Step 3: Commit**

```bash
git add tests/Fixture.Tests.ps1
git commit -m "test: assert fixture oracle bands and match-pattern behaviors

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 3: Describe 1 — filter assertions (`-MinimumConfidence`, `-SecurityGroupsOnly`)

**Files:**
- Modify: `tests/Fixture.Tests.ps1`

- [ ] **Step 1: Add these `It` blocks inside the same `Describe 'Fixture: engine pipeline (Northwind discovery)'`, after the decoy test and before the Describe's closing `}`**

```powershell
    It 'MinimumConfidence High keeps Confirmed+High and drops Medium' {
        $high = Select-DiscoveryResults -Results $script:cand -MinimumConfidence 'High'
        $high.Count | Should -Be 9
        $high.Name  | Should -Not -Contain 'Global Logistics Stewards'   # Medium -> dropped
        $high.Name  | Should -Contain 'Project Atlas Team'               # Confirmed -> kept
    }

    It 'SecurityGroupsOnly drops the distribution group (Northwind Support)' {
        $secGroups = @($script:data.Groups | Where-Object { "$($_.GroupCategory)" -eq 'Security' })
        $discoveryInput = $script:data.InputData
        $knownKeys = @{}
        foreach ($k in $discoveryInput.KnownGroups)   { $knownKeys[(Get-GroupLookupKey -Domain $k.Domain -Identity $k.Identity)] = $true }
        $excludeKeys = @{}
        foreach ($e in $discoveryInput.ExcludeGroups) { $excludeKeys[(Get-GroupLookupKey -Domain $e.Domain -Identity $e.Identity)] = $true }

        $c = Find-CandidateGroups -Groups $secGroups -Keywords $discoveryInput.Keywords `
            -VendorUsers $script:data.VendorUsers -KnownKeys $knownKeys -ExcludeKeys $excludeKeys
        $c = Expand-VendorGroupClosure -Results $c
        $s = Select-DiscoveryResults -Results $c

        $s.Count | Should -Be 9
        $s.Name  | Should -Not -Contain 'Northwind Support'
        $s.Name  | Should -Contain 'Northwind Traders Admins'
    }
```

- [ ] **Step 2: Run the file and confirm all assertions pass**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path ./tests/Fixture.Tests.ps1 -Output Detailed"`
Expected: 10 tests, all PASS.

- [ ] **Step 3: Commit**

```bash
git add tests/Fixture.Tests.ps1
git commit -m "test: assert MinimumConfidence and SecurityGroupsOnly filtering over fixture

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 4: Describe 2 — public `Find-VendorAdGroup` path, then full suite + lint

**Files:**
- Modify: `tests/Fixture.Tests.ps1`

- [ ] **Step 1: Append this second `Describe` block to the END of `tests/Fixture.Tests.ps1` (after the closing `}` of Describe 1)**

```powershell
Describe 'Fixture: public Find-VendorAdGroup (Northwind discovery)' {
    BeforeAll {
        $script:outDir = Join-Path ([System.IO.Path]::GetTempPath()) ("fx_" + [guid]::NewGuid())
        Mock -CommandName Get-AdDiscoveryData -MockWith {
            $d = Get-FixtureDiscoveryData -FixtureDir $script:fixtureDir
            [pscustomobject]@{
                Groups        = $d.Groups
                VendorUsers   = $d.VendorUsers
                DnIndex       = $d.DnIndex
                FailedDomains = @()
                Warnings      = @()
            }
        }
        $inDir = Join-Path $script:fixtureDir 'discovery-input'
        Find-VendorAdGroup `
            -UsersCsv        (Join-Path $inDir 'users.csv') `
            -DomainsCsv      (Join-Path $inDir 'domains.csv') `
            -KeywordsCsv     (Join-Path $inDir 'keywords.csv') `
            -KnownGroupsCsv  (Join-Path $inDir 'known.csv') `
            -ExcludeGroupsCsv (Join-Path $inDir 'exclude.csv') `
            -OutputDirectory $script:outDir -Formats @('Csv','Html') | Out-Null

        $script:csvRows = @(Import-Csv (Join-Path $script:outDir 'vendor-group-discovery.csv'))
        $script:html    = Get-Content (Join-Path $script:outDir 'vendor-group-discovery.html') -Raw
    }
    AfterAll { Remove-Item -Recurse -Force $script:outDir -ErrorAction SilentlyContinue }

    It 'writes a CSV with one row per surfaced group' {
        $script:csvRows.Count | Should -Be 10
    }

    It 'records the closure reason in the CSV' {
        $row = $script:csvRows | Where-Object { $_.Name -eq 'Global Logistics Stewards' }
        $row.MatchReasons | Should -Match 'NestedVendorGroup'
    }

    It 'records the known group as Confirmed in the CSV' {
        $row = $script:csvRows | Where-Object { $_.Name -eq 'Project Atlas Team' }
        $row.Confidence | Should -Be 'Confirmed'
    }

    It 'excludes decoy groups from the CSV' {
        $script:csvRows.Name | Should -Not -Contain 'Contoso Service Desk'
    }

    It 'flags vendor members with an asterisk in the CSV' {
        $row = $script:csvRows | Where-Object { $_.Name -eq 'Northwind Traders Admins' }
        $row.Members | Should -Match '\*Maria Hale'
    }

    It 'writes an HTML report containing the groups and a header per result domain' {
        $script:html | Should -Match '<html'
        $script:html | Should -Match 'Northwind Traders Admins'
        foreach ($dom in @('corp.globex.com','emea.globex.com','apac.globex.local','dmz.globex.net')) {
            $script:html | Should -Match ([regex]::Escape($dom))
        }
    }
}
```

- [ ] **Step 2: Run the file and confirm all assertions pass**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path ./tests/Fixture.Tests.ps1 -Output Detailed"`
Expected: 16 tests, all PASS.

- [ ] **Step 3: Run the FULL suite to confirm no regressions**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path ./tests -Output Detailed"`
Expected: all pass (62 existing + 16 new = 78).

- [ ] **Step 4: Run PSScriptAnalyzer and confirm clean**

Run: `pwsh -NoProfile -Command "Invoke-ScriptAnalyzer -Path ./tests/Fixture.Tests.ps1 -Settings ./PSScriptAnalyzerSettings.psd1"`
Expected: no output. (If `PSAvoidAssignmentToAutomaticVariable` fires, you used `$input` somewhere — rename to `$discoveryInput` and re-run.)

- [ ] **Step 5: Commit**

```bash
git add tests/Fixture.Tests.ps1
git commit -m "test: assert public Find-VendorAdGroup CSV/HTML output over fixture

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Self-review notes (reconciled against the spec)

- **Spec coverage:** Describe 1 setup + exact-10 (Task 1); band-per-group, closure, known, cross-domain SID, description-user, precision, vendor-member flag (Task 2); MinimumConfidence + SecurityGroupsOnly (Task 3); public CSV row count, closure-in-CSV, known-in-CSV, decoy-absent, vendor-`*`-in-CSV, HTML populated + 4 domain headers (Task 4). Every spec `It` is present. Console-only assertions intentionally omitted (covered by `Write-ConsoleSummary.Tests.ps1`), per spec.
- **Placeholder scan:** none — every step ships complete, runnable code and exact commands.
- **Type/name consistency:** `$script:data` (.Groups/.VendorUsers/.DnIndex/.InputData), `$script:expectedBand`, `$script:absent`, `$script:cand`, `$script:sel`, `$script:byName`, `$script:fixtureDir`, `$script:outDir`, `$script:csvRows`, `$script:html` are used consistently across tasks. Helper/function names (`Get-FixtureDiscoveryData`, `Get-GroupLookupKey`, `Find-CandidateGroups`, `Expand-VendorGroupClosure`, `Select-DiscoveryResults`, `Resolve-ResultDisplay`, `Find-VendorAdGroup`, `Get-AdDiscoveryData`) match the existing source. No `$input` variable used (automatic-variable hazard avoided).
