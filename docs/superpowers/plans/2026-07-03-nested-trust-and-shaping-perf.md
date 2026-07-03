# Nested-Trust Loophole & Shaping Performance Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop generic built-in group names (e.g. `Administrators`) from seeding description-name trust via `NestedVendorGroup`, fix the broken LDAP clause batching, and replace per-member serial `Get-ADObject` shaping with batched, engine-gated member resolution.

**Architecture:** Three independent defects compound in prod: (1) `Test-TrustedNameSource` accepts `NestedVendorGroup` as trust evidence, so a built-in group holding one vendor-owned child turns its generic name into an LDAP description-search token — in prod.example.com the word "Administrators" matched 649 group descriptions, exploding the candidate set to 1005 and its members to 36,851; (2) `Get-Batches` output is consumed through `@(...)`, which defeats the `,`-wrap — every "batched" search actually sends ALL clauses in one filter (observed: 159,514-char filter), and clause arrays get space-join-corrupted through `[string[]]` binding; (3) report shaping resolves every member of every candidate — including engine-rejected junk — one serial `Get-ADObject` round trip at a time (28,066 fetches ≈ 43 min). Fixes: tighten the shared trust predicate; introduce a real, size-aware clause batcher; batch member resolution behind a global engine pre-pass so only reportable groups pay member-resolution cost.

**Tech Stack:** Windows PowerShell 5.1 target, Pester 5 on Linux `pwsh` for tests, RSAT `ActiveDirectory` cmdlets (stubbed/mocked in tests).

## Global Constraints

- Target Windows PowerShell 5.1 — no PS6+ syntax (no `??`, no `ForEach-Object -Parallel`, no ternary).
- Only `Get-AdDiscoveryData` may call AD cmdlets; engine/report functions stay pure.
- Engine functions return arrays with the leading-comma idiom; call with plain assignment, never wrap calls in `@( )`.
- Report output stays hardened (no change to `Protect-CsvCell` / HTML escaping paths in this plan).
- Every new/changed engine or AD behavior gets a matching `*.Tests.ps1` case; end-to-end behavior changes get fixture oracle updates.
- Run after each task: `pwsh -NoProfile -Command "Invoke-Pester -Path ./tests -Output Detailed"` and `pwsh -NoProfile -Command "Invoke-ScriptAnalyzer -Path . -Recurse -Settings ./PSScriptAnalyzerSettings.psd1"`.
- Commit after each task with a conventional-commit message ending in `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

**Prod evidence anchoring the design** (from the 2026-07-03 prod.example.com run, discovery.log):

- `shaped 1005 group(s) with 36851 member references(s) (28066 directory fetches, 8785 cache hits) in 2564382 ms` — 91 ms per serial fetch; shaping is 83% of the 3073 s domain time.
- Administrators: 12 member groups, 1 vendor-owned (2 vendor owners, 9 known vendor users). 649 group descriptions in the domain contain the exact word "Administrators".
- `group search (direct vendor membership): 40 result(s) in 350 ms, filter 159514 chars` — proves one filter carried every member clause (batching broken) and that the DC accepts ~160 KB filters.
- `group search (description user-token search): 59 result(s) in 55026 ms, filter 17924 chars` — contains-searches are unindexed full scans; **fewer, larger** filters are cheaper than many small ones, so the batch caps below are deliberately generous (1000 clauses / 120,000 chars).

---

### Task 1: Exclude NestedVendorGroup from trusted-name seeding

**Files:**
- Modify: `src/Engine/Test-TrustedNameSource.ps1`
- Test: `tests/Test-TrustedNameSource.Tests.ps1`
- Test: `tests/Expand-VendorGroupClosure.Tests.ps1`
- Test: `tests/Get-AdDiscoveryData.Tests.ps1`

**Interfaces:**
- Consumes: existing `Test-TrustedNameSource -Result <r> -Rank <hashtable>` predicate (shared by `Expand-VendorGroupClosure` and the fetch layer).
- Produces: same signature, tightened semantics — `NestedVendorGroup` no longer counts as independent evidence. Task 2's fixture oracle relies on this.

- [ ] **Step 1: Write the failing unit tests**

Append inside `Describe 'Test-TrustedNameSource'` in `tests/Test-TrustedNameSource.Tests.ps1` (the file's `BeforeAll` already defines `New-Candidate($confidence, $reasons, $known, $allVendor)` and `New-Reason($pattern)`):

```powershell
    It 'does not trust a group whose only non-member signal is nested vendor containment' {
        # A built-in group ("Administrators") holding one vendor-owned child must
        # not turn its generic name into a description-search token: in prod that
        # matched 649 unrelated group descriptions.
        $r = New-Candidate 'Medium' @(New-Reason 'NestedVendorGroup')
        Test-TrustedNameSource -Result $r -Rank $script:rank | Should -BeFalse
    }
    It 'does not trust nested containment stacked with vendor membership' {
        $r = New-Candidate 'High' @((New-Reason 'NestedVendorGroup'), (New-Reason 'MemberVendorUser'))
        Test-TrustedNameSource -Result $r -Rank $script:rank | Should -BeFalse
    }
    It 'still trusts a nested parent that also has an independent signal' {
        $r = New-Candidate 'High' @((New-Reason 'NestedVendorGroup'), (New-Reason 'NameKeyword'))
        Test-TrustedNameSource -Result $r -Rank $script:rank | Should -BeTrue
    }
```

- [ ] **Step 2: Run tests to verify the first two fail**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path ./tests/Test-TrustedNameSource.Tests.ps1 -Output Detailed"`
Expected: 2 new failures ("Expected $false, but got $true"); third new test passes; existing tests pass.

- [ ] **Step 3: Tighten the predicate**

In `src/Engine/Test-TrustedNameSource.ps1` replace the body lines

```powershell
    if ($Result.IsKnown) { return $true }
    if ($Rank[$Result.Confidence] -lt $Rank['Low']) { return $false }
    $nonMemberReasons = @(@($Result.Reasons) | Where-Object { $_.Pattern -ne 'MemberVendorUser' })
    if ($nonMemberReasons.Count -gt 0) { return $true }
    return [bool]$Result.AllMembersVendor
```

with

```powershell
    if ($Result.IsKnown) { return $true }
    if ($Rank[$Result.Confidence] -lt $Rank['Low']) { return $false }
    # Independent evidence = a signal about THIS group's own identity (name,
    # container, owner, description). Vendor membership is not (a vendor account
    # in "Domain Admins" must not trust that name) and neither is nested vendor
    # containment (a vendor-owned child inside built-in "Administrators" must
    # not trust THAT name either — its description mentions are almost always
    # unrelated). DescriptionGroup stays trusted so transitive chains propagate.
    $independentReasons = @(@($Result.Reasons) |
        Where-Object { $_.Pattern -ne 'MemberVendorUser' -and $_.Pattern -ne 'NestedVendorGroup' })
    if ($independentReasons.Count -gt 0) { return $true }
    return [bool]$Result.AllMembersVendor
```

Also update the function's header comment: change "Vendor membership alone is not independent evidence" paragraph to say vendor membership **and nested vendor containment** alone are not independent evidence.

- [ ] **Step 4: Run the unit tests, verify all pass**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path ./tests/Test-TrustedNameSource.Tests.ps1 -Output Detailed"`
Expected: PASS (all, including the 3 new).

- [ ] **Step 5: Write the failing closure regression test**

Append inside `Describe 'Expand-VendorGroupClosure'` in `tests/Expand-VendorGroupClosure.Tests.ps1` (its `BeforeAll` defines `New-Result($name,$dn,$member,$score,$confidence,$known)` and `New-Reason($pattern,$value)`):

```powershell
    It 'does not promote description mentions of a parent trusted only via nested containment' {
        $child = New-Result 'Acme Ops' 'CN=Acme Ops,DC=c' @() 3 'High'
        $child.Reasons = @(New-Reason 'Owner' 'jsmith')
        $parent = New-Result 'Administrators' 'CN=Administrators,CN=Builtin,DC=c' @('CN=Acme Ops,DC=c') 0 'None'
        $decoy = New-Result 'Print Ops' 'CN=Print Ops,DC=c' @() 0 'None'
        foreach ($r in @($child, $parent, $decoy)) {
            $r | Add-Member Description ''; $r | Add-Member Info ''
        }
        $decoy.Description = 'Administrators of the print estate.'
        $out = Expand-VendorGroupClosure -Results @($child, $parent, $decoy)
        ($out | Where-Object Name -eq 'Administrators').Confidence | Should -Be 'Medium'
        ($out | Where-Object Name -eq 'Print Ops').Confidence | Should -Be 'None'
    }
```

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path ./tests/Expand-VendorGroupClosure.Tests.ps1 -Output Detailed"`
Expected: PASS already (Step 3 changed the shared predicate) — but verify the Administrators assertion is Medium, proving `NestedVendorGroup` scoring itself is untouched. If 'Print Ops' shows Medium, Step 3 regressed.

- [ ] **Step 6: Write the fetch-layer gating test**

Append inside `Describe 'Get-AdDiscoveryData'` in `tests/Get-AdDiscoveryData.Tests.ps1`, modeled on the existing `does not issue a description search for a name whose only signal is a mixed vendor membership` test:

```powershell
    It 'does not issue a description search for a built-in name trusted only via nested vendor containment' {
        # Administrators holds one vendor-OWNED child (Owner reason -> High).
        # The parent gains NestedVendorGroup (Medium) and must surface, but its
        # generic name must NOT become an LDAP description-search token.
        $userDn  = 'CN=John Smith,OU=Vendor,DC=corp,DC=example,DC=com'
        $childDn = 'CN=Acme Host Ops,OU=Groups,DC=corp,DC=example,DC=com'
        $adminDn = 'CN=Administrators,CN=Builtin,DC=corp,DC=example,DC=com'
        Mock -CommandName Get-ADObject -MockWith { $null }
        Mock -CommandName Get-ADUser -MockWith {
            [pscustomobject]@{ SamAccountName='jsmith'; DisplayName='John Smith'; GivenName='John'; sn='Smith'
                CN='John Smith'; Name='John Smith'; UserPrincipalName='jsmith@vendor.com'; mail=$null
                DistinguishedName=$userDn; objectSid='S-1-5-21-1-2-3-1001'; memberOf=@() }
        }
        Mock -CommandName Get-ADGroup -ParameterFilter { $LDAPFilter -like "*member=$userDn*" } -MockWith {
            [pscustomobject]@{ Name='Acme Host Ops'; DistinguishedName=$childDn
                description=''; info=''; managedBy=$userDn; GroupScope='Global'; GroupCategory='Security' }
        }
        Mock -CommandName Get-ADGroup -ParameterFilter { $LDAPFilter -like "*member=$childDn*" } -MockWith {
            [pscustomobject]@{ Name='Administrators'; DistinguishedName=$adminDn
                description=''; info=''; managedBy=''; GroupScope='DomainLocal'; GroupCategory='Security' }
        }
        Mock -CommandName Get-ADGroup -ParameterFilter { $Identity -eq $childDn } -MockWith {
            [pscustomobject]@{ Name='Acme Host Ops'; DistinguishedName=$childDn
                description=''; info=''; managedBy=$userDn; member=@($userDn); memberof=@($adminDn)
                GroupScope='Global'; GroupCategory='Security'; mail=$null; adminCount=$null
                whenCreated=$null; whenChanged=$null }
        }
        Mock -CommandName Get-ADGroup -ParameterFilter { $Identity -eq $adminDn } -MockWith {
            [pscustomobject]@{ Name='Administrators'; DistinguishedName=$adminDn
                description=''; info=''; managedBy=''
                member=@($childDn, 'CN=Jane Roe,OU=Staff,DC=corp,DC=example,DC=com'); memberof=@()
                GroupScope='DomainLocal'; GroupCategory='Security'; mail=$null; adminCount=1
                whenCreated=$null; whenChanged=$null }
        }
        Mock -CommandName Get-ADGroup -MockWith { @() }
        $inp = [pscustomobject]@{
            Users       = @([pscustomobject]@{ SamAccountName='jsmith'; DisplayName='John Smith' })
            Keywords    = @()
            KnownGroups = @()
            Domains     = @([pscustomobject]@{ Domain='corp.example.com'; Server='dc1'; Name='Corp' })
        }

        $data = Get-AdDiscoveryData -InputData $inp
        $data.Groups.Name | Should -Contain 'Administrators'   # still a candidate for the report
        Should -Invoke Get-ADGroup -Exactly -Times 0 -ParameterFilter {
            $LDAPFilter -like '*description=*Administrators**'
        }
        # The vendor-owned child's own name has independent evidence (Owner) and
        # stays a trusted description token.
        Should -Invoke Get-ADGroup -Exactly -Times 1 -ParameterFilter {
            $LDAPFilter -like '*description=*Acme Host Ops**'
        }
    }
```

- [ ] **Step 7: Run the AD tests, verify pass**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path ./tests/Get-AdDiscoveryData.Tests.ps1 -Output Detailed"`
Expected: PASS. (The new test would fail before Step 3 with 1 unexpected `description=*Administrators*` search.)

- [ ] **Step 8: Full suite, lint, commit**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path ./tests -Output Detailed"` → all green.
Run: `pwsh -NoProfile -Command "Invoke-ScriptAnalyzer -Path . -Recurse -Settings ./PSScriptAnalyzerSettings.psd1"` → no new findings.

```bash
git add src/Engine/Test-TrustedNameSource.ps1 tests/Test-TrustedNameSource.Tests.ps1 tests/Expand-VendorGroupClosure.Tests.ps1 tests/Get-AdDiscoveryData.Tests.ps1
git commit -m "fix: stop nested vendor containment from seeding description-name trust

A built-in group (Administrators) holding one vendor-owned child gained
NestedVendorGroup, which Test-TrustedNameSource accepted as independent
evidence, turning the generic name into a trusted description token. In
prod that matched 649 unrelated group descriptions, exploding one domain
to 1005 candidates and 43 minutes of member shaping. NestedVendorGroup
still scores (the parent still surfaces); it just no longer seeds name
trust, mirroring the existing MemberVendorUser rule.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: Fixture — Administrators scenario and oracle

**Files:**
- Modify: `tests/fixtures/New-DiscoveryFixture.ps1` (group table)
- Regenerate: `tests/fixtures/directory.json`, `tests/fixtures/discovery-input/*.csv`
- Modify: `tests/fixtures/README.md` (oracle table + counts)
- Test: `tests/Fixture.Tests.ps1`

**Interfaces:**
- Consumes: Task 1's tightened `Test-TrustedNameSource`.
- Produces: fixture oracle grows from 13 to 15 surfaced groups: adds `Platform Host Admins` (**High**) and `Administrators` (**Medium**); decoy `Workstation Local Rights` must NOT surface.

- [ ] **Step 1: Add three group rows to the generator**

In `tests/fixtures/New-DiscoveryFixture.ps1`, append to `$groupRows` after the `SQL Backup Operators` row:

```powershell
    # Vendor-owned child nested into built-in Administrators (prod regression
    # scenario): Owner + vendor members -> High, and its name IS trusted.
    @{ Name='Platform Host Admins'; Dom='corp'; Cont='NW'; Desc='Northwind-managed platform host administration.'; Owner='kvolkov'; Members=@('rsantos','awright'); MemberGroups=@(); Fsid=@(); Scope='Global'; Cat='Security'; Admin=$true; Mail=$null; Org='Northwind' }
    # Built-in parent: gains NestedVendorGroup (Medium) from the child above and
    # must surface, but its generic name must NOT seed description trust.
    @{ Name='Administrators'; Dom='corp'; Cont='BI'; Desc='Built-in administrators of the domain.'; Owner=''; Members=@('ghunt','amorgan'); MemberGroups=@('Platform Host Admins','Globex IT Admins'); Fsid=@(); Scope='DomainLocal'; Cat='Security'; Admin=$true; Mail=$null; Org='Globex' }
    # Decoy: description mentions "Administrators" as an exact word but has no
    # vendor link; must never surface (nested-trust regression guard).
    @{ Name='Workstation Local Rights'; Dom='corp'; Cont='GR'; Desc='Grants local Administrators rights on managed workstations.'; Owner=''; Members=@('dwebb'); MemberGroups=@(); Fsid=@(); Scope='Global'; Cat='Security'; Admin=$false; Mail=$null; Org='Globex' }
```

Note: `Cont='BI'` and `Scope`/`Cat` values follow the existing `Domain Admins` row's conventions; `kvolkov`, `rsantos`, `awright` are existing Northwind corp users; `ghunt`, `amorgan`, `dwebb` are existing Globex users. Verify `dwebb` exists in the user table (it appears in `All Staff`); if it is apac-homed, use `bturner` instead — members must be same-domain sams.

- [ ] **Step 2: Regenerate the fixture**

Run: `pwsh -NoProfile -File ./tests/fixtures/New-DiscoveryFixture.ps1`
Expected: rewrites `directory.json` + `discovery-input/*.csv` deterministically. `git diff --stat` shows only those files.

- [ ] **Step 3: Update Fixture.Tests.ps1 expectations (they now fail — run first to see)**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path ./tests/Fixture.Tests.ps1 -Output Detailed"`
Expected: failures in the exact-set/count assertions (13 vs 15).

Then in `tests/Fixture.Tests.ps1`:
- Add to `$script:expectedBand`:
  ```powershell
        'Platform Host Admins'      = 'High'
        'Administrators'            = 'Medium'
  ```
- Update `It 'surfaces exactly the 13 expected groups'` → rename to `'surfaces exactly the 15 expected groups'` (the assertion itself compares against `$script:expectedBand.Keys`, so only the title and any hardcoded count change).
- Update the `$high.Count | Should -Be 9` assertion → `10`.
- Update the security-only count `$s.Count | Should -Be 12` → `14` (both new surfaced groups are Security; verify actual value from the failure message).
- Update `$script:csvRows.Count | Should -Be 13` → `15`.
- Add a dedicated regression test:

```powershell
    It 'surfaces Administrators via nested containment but not groups that merely mention it' {
        $g = $script:byName['Administrators']
        $g.Confidence | Should -Be 'Medium'
        @($g.Reasons | Where-Object { $_.Pattern -eq 'NestedVendorGroup' }).Value | Should -Contain 'Platform Host Admins'
        $script:sel.Name | Should -Not -Contain 'Workstation Local Rights'
    }
```

(Match the surrounding tests' access to `$script:byName` / `$script:sel` — reuse whatever variable the existing `Domain Admins` test uses.)

- [ ] **Step 4: Run fixture tests until green**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path ./tests/Fixture.Tests.ps1 -Output Detailed"`
Expected: PASS. If `Administrators` comes out High instead of Medium, check whether `Globex IT Admins` also reached Medium+ (it must not — it has no vendor signal); adjust only if the engine legitimately stacks a second reason.

- [ ] **Step 5: Update the fixture README oracle**

In `tests/fixtures/README.md`:
- Update the group count line ("24 groups …") to 27.
- Add two oracle rows to the expected-result table:
  ```markdown
  | Platform Host Admins | corp (vendor OU) | **High** | Vendor owner (kvolkov) + vendor members; nested into built-in Administrators |
  | Administrators | corp (`CN=Builtin`) | **Medium** | **Nested containment** — holds vendor-owned Platform Host Admins. Its generic name is **not trusted** for description matching |
  ```
- Extend the "must not surface" paragraph to mention `Workstation Local Rights` (description mentions "Administrators", no vendor link).

- [ ] **Step 6: Full suite, smoke test, commit**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path ./tests -Output Detailed"` → all green.
Run: `pwsh -NoProfile -File ./tests/fixtures/Show-FixtureDiscovery.ps1` → console summary shows 15 groups, no `Workstation Local Rights`.

```bash
git add tests/fixtures/ tests/Fixture.Tests.ps1
git commit -m "test: fixture regression scenario for nested-containment name trust

Adds vendor-owned Platform Host Admins nested in built-in Administrators
(surfaces Medium via NestedVendorGroup) and decoy Workstation Local
Rights whose description mentions Administrators (must never surface).

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: Real, size-aware LDAP clause batching

**Files:**
- Create: `src/Ad/Get-LdapClauseBatches.ps1`
- Create: `tests/Get-LdapClauseBatches.Tests.ps1`
- Modify: `src/Ad/Get-AdDiscoveryData.ps1` (remove nested `Get-Batches`, replace 5 call sites, retire `$ldapBatchSize`)
- Test: `tests/Get-AdDiscoveryData.Tests.ps1` (corruption canary)

**Interfaces:**
- Consumes: nothing new.
- Produces: `Get-LdapClauseBatches -Clauses [string[]] -MaxClauses [int]=1000 -MaxChars [int]=120000` returning `object[]` of `string[]` batches (safe to `foreach` directly). Task 4 uses it for member-DN batches.

**Background for the implementer:** the current nested `Get-Batches` ends with `return ,$batches`. The comma makes the pipeline emit the ArrayList as ONE item; the call sites then do `foreach ($batch in @(Get-Batches ...))`, so the loop runs once with `$batch` = the ArrayList of all batches, and `New-LdapOrFilter -Clauses $batch` stringifies each inner `object[]` by space-joining it. Net effect: batching never happens (one giant filter per phase — prod showed 159,514 chars) and clauses are glued with spaces. Empirically verified with a 1300-item input: outer count 1, loop iterations 1.

- [ ] **Step 1: Write the failing unit tests**

Create `tests/Get-LdapClauseBatches.Tests.ps1`:

```powershell
BeforeAll { . "$PSScriptRoot/_TestHelpers.ps1" }

Describe 'Get-LdapClauseBatches' {
    It 'yields one iterable batch per element with the clause cap honored' {
        $batches = @(Get-LdapClauseBatches -Clauses @('(a=1)', '(a=2)', '(a=3)') -MaxClauses 2)
        $batches.Count | Should -Be 2
        @($batches[0]).Count | Should -Be 2
        @($batches[1]).Count | Should -Be 1
        @($batches[0])[0] | Should -Be '(a=1)'
    }
    It 'starts a new batch when the character budget would overflow' {
        $long = '(a=' + ('x' * 50) + ')'
        $batches = @(Get-LdapClauseBatches -Clauses @($long, $long) -MaxChars 60)
        $batches.Count | Should -Be 2
    }
    It 'keeps an oversized single clause in its own batch rather than dropping it' {
        $huge = '(a=' + ('x' * 500) + ')'
        $batches = @(Get-LdapClauseBatches -Clauses @($huge) -MaxChars 60)
        $batches.Count | Should -Be 1
        @($batches[0]).Count | Should -Be 1
    }
    It 'skips null or empty clauses' {
        $batches = @(Get-LdapClauseBatches -Clauses @('(a=1)', '', $null, '(a=2)'))
        $batches.Count | Should -Be 1
        @($batches[0]).Count | Should -Be 2
    }
    It 'returns an empty array for no clauses' {
        $batches = @(Get-LdapClauseBatches -Clauses @())
        $batches.Count | Should -Be 0
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path ./tests/Get-LdapClauseBatches.Tests.ps1 -Output Detailed"`
Expected: FAIL — `Get-LdapClauseBatches` is not recognized.

- [ ] **Step 3: Implement**

Create `src/Ad/Get-LdapClauseBatches.ps1`:

```powershell
function Get-LdapClauseBatches {
    # Splits LDAP filter clauses into batches bounded by clause count and total
    # character size so OR'd filters stay well under directory limits (a prod DC
    # accepted a 159 KB filter, so the defaults keep a comfortable margin while
    # minimizing the number of searches -- unindexed contains-filters cost one
    # full directory scan PER SEARCH, so fewer, larger batches are cheaper).
    #
    # Returns object[] of string[] batches. Callers iterate the result directly
    # (foreach ($batch in Get-LdapClauseBatches ...)); each element is one batch.
    # NOTE: no ,-wrapping on return -- the pipeline unrolls exactly one level,
    # emitting each string[] batch as one item. A leading comma here re-creates
    # the flattening bug this function replaces.
    [CmdletBinding()]
    param(
        [string[]]$Clauses,
        [int]$MaxClauses = 1000,
        [int]$MaxChars = 120000
    )
    $batches = New-Object System.Collections.Generic.List[object]
    $current = New-Object System.Collections.Generic.List[string]
    $currentChars = 0
    foreach ($clause in @($Clauses)) {
        if ([string]::IsNullOrEmpty($clause)) { continue }
        $overflow = ($current.Count -ge $MaxClauses) -or
            ($current.Count -gt 0 -and ($currentChars + $clause.Length) -gt $MaxChars)
        if ($overflow) {
            $batches.Add($current.ToArray())
            $current = New-Object System.Collections.Generic.List[string]
            $currentChars = 0
        }
        $current.Add($clause)
        $currentChars += $clause.Length
    }
    if ($current.Count -gt 0) { $batches.Add($current.ToArray()) }
    return $batches.ToArray()
}
```

- [ ] **Step 4: Run unit tests, verify pass**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path ./tests/Get-LdapClauseBatches.Tests.ps1 -Output Detailed"`
Expected: PASS (5/5).

- [ ] **Step 5: Write the failing corruption-canary test**

Append inside `Describe 'Get-AdDiscoveryData'` in `tests/Get-AdDiscoveryData.Tests.ps1`:

```powershell
    It 'sends every batched OR filter intact - no space-joined clause corruption' {
        # Regression: Get-Batches output was consumed through @(...), which made
        # the loop run once with ALL batches and space-join them into one giant
        # filter (prod: one 159,514-char "batched" filter).
        $script:capturedFilters = New-Object System.Collections.Generic.List[string]
        Mock -CommandName Get-ADObject -MockWith { $null }
        Mock -CommandName Get-ADUser -MockWith {
            @(
                [pscustomobject]@{ SamAccountName='jsmith'; DisplayName='John Smith'; GivenName='John'; sn='Smith'
                    CN='John Smith'; Name='John Smith'; UserPrincipalName='jsmith@vendor.com'; mail=$null
                    DistinguishedName='CN=John Smith,OU=Vendor,DC=corp,DC=example,DC=com'
                    objectSid='S-1-5-21-1-2-3-1001'; memberOf=@() }
                [pscustomobject]@{ SamAccountName='mjones'; DisplayName='Mary Jones'; GivenName='Mary'; sn='Jones'
                    CN='Mary Jones'; Name='Mary Jones'; UserPrincipalName='mjones@vendor.com'; mail=$null
                    DistinguishedName='CN=Mary Jones,OU=Vendor,DC=corp,DC=example,DC=com'
                    objectSid='S-1-5-21-1-2-3-1002'; memberOf=@() }
            )
        }
        Mock -CommandName Get-ADGroup -MockWith { $script:capturedFilters.Add("$LDAPFilter"); @() }
        $inp = [pscustomobject]@{
            Users       = @(
                [pscustomobject]@{ SamAccountName='jsmith'; DisplayName='John Smith' }
                [pscustomobject]@{ SamAccountName='mjones'; DisplayName='Mary Jones' }
            )
            Keywords    = @()
            KnownGroups = @()
            Domains     = @([pscustomobject]@{ Domain='corp.example.com'; Server='dc1'; Name='Corp' })
        }
        $null = Get-AdDiscoveryData -InputData $inp
        $script:capturedFilters.Count | Should -BeGreaterThan 0
        foreach ($f in $script:capturedFilters) {
            $f | Should -Not -Match '\)\s+\('   # adjacent clauses glued with whitespace
        }
        # Both users' member clauses must still be present across the filters.
        ($script:capturedFilters -join "`n") | Should -Match 'member=CN=John Smith'
        ($script:capturedFilters -join "`n") | Should -Match 'member=CN=Mary Jones'
    }
```

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path ./tests/Get-AdDiscoveryData.Tests.ps1 -Output Detailed"`
Expected: the new test FAILS on the `'\)\s+\('` assertion (with ≥2 users the flattened batches are space-joined).

- [ ] **Step 6: Replace the call sites**

In `src/Ad/Get-AdDiscoveryData.ps1`:

1. Delete the nested `function Get-Batches { ... }` block entirely.
2. Delete the `$ldapBatchSize = 40` line and update the acquisition log line that prints it:
   from `"...; sam batch {4}, ldap batch {5}"` (formatted with `$samBatchSize, $ldapBatchSize`)
   to `"...; sam batch {4}"` (drop the last format arg).
3. Replace all five `foreach ($batch in @(Get-Batches -Items <X> -BatchSize $ldapBatchSize))` loops — direct vendor membership (`$memberClauses.ToArray()`), keyword search (`$keywordClauses.ToArray()`), description user-token search (`$tokenClauses.ToArray()`), nested parent lookup (`$parentClauses`), trusted-name description search (`$nameClauses.ToArray()`) — with:

```powershell
        foreach ($batch in Get-LdapClauseBatches -Clauses <X>) {
```

(keep each loop body unchanged — `$batch` is now a real `string[]`).

- [ ] **Step 7: Run AD tests + full suite**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path ./tests/Get-AdDiscoveryData.Tests.ps1 -Output Detailed"`
Expected: PASS including the canary. Watch specifically the trusted-name-ledger tests (`'discovers description-owned groups transitively and queries each trusted name once per domain'`, `'maintains the trusted-name query ledger independently for each domain'`) — their `Should -Invoke ... -Times N` counts assume clause→search mapping; with default caps (1000/120000) small test inputs still produce exactly one search per phase, so counts should hold. If one fails, the expected count changed because batching now actually works — verify the new count is correct by hand (clauses ÷ caps) before updating the assertion.

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path ./tests -Output Detailed"` → all green.

- [ ] **Step 8: Commit**

```bash
git add src/Ad/Get-LdapClauseBatches.ps1 tests/Get-LdapClauseBatches.Tests.ps1 src/Ad/Get-AdDiscoveryData.ps1 tests/Get-AdDiscoveryData.Tests.ps1
git commit -m "fix: LDAP clause batching never batched; add size-aware batcher

Get-Batches returned its ArrayList ,-wrapped while call sites consumed it
via @(...), so each foreach ran once with every batch and [string[]]
binding space-joined the clauses into one giant filter (prod log: a
'batched' 159,514-char filter). Replace with Get-LdapClauseBatches,
bounded by clause count and characters (1000 / 120 KB -- generous on
purpose: unindexed contains-searches cost one full scan per query, so
fewer, larger filters are cheaper, and prod proved ~160 KB is accepted).

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: Batched member resolution

**Files:**
- Modify: `src/Ad/Get-AdDiscoveryData.ps1` (replace `Resolve-AdMemberObject` with `Resolve-AdMemberObjectBatch`; rework the shaping loop; extend `$queryStats`; update log lines)
- Test: `tests/Get-AdDiscoveryData.Tests.ps1` (update Get-ADObject mocks/assertions; add unresolved-DN and single-search tests)

**Interfaces:**
- Consumes: `Get-LdapClauseBatches` (Task 3), existing `Add-CachedMemberObject`, `New-ExactFilter`, `New-LdapOrFilter`, `$memberObjectProps`, `$memberObjectCache`, `$queryStats`.
- Produces: nested function `Resolve-AdMemberObjectBatch -Common [hashtable] -Domain [string] -DistinguishedNames [string[]] -Cache [hashtable]` — after it returns, **every** requested DN has a cache entry shaped `{ DistinguishedName; SamAccountName; DisplayName; Name; ObjectClass }` (empty strings when unresolved). Task 5 calls this from the post-pass.

- [ ] **Step 1: Update the existing per-member mock tests to expect batched lookups (they will fail first)**

In `tests/Get-AdDiscoveryData.Tests.ps1`, test `'hydrates direct member directory objects for report shaping'`:

Replace

```powershell
        Mock -CommandName Get-ADObject -ParameterFilter { $Identity -eq $memberDn } -MockWith {
            [pscustomobject]@{ DistinguishedName=$memberDn; sAMAccountName='bjones'
                displayName='Bob Jones'; name='Bob Jones'; objectClass=@('top','person','user') }
        }
```

with

```powershell
        Mock -CommandName Get-ADObject -ParameterFilter { $LDAPFilter -like "*distinguishedName=$memberDn*" } -MockWith {
            [pscustomobject]@{ DistinguishedName=$memberDn; sAMAccountName='bjones'
                displayName='Bob Jones'; name='Bob Jones'; objectClass=@('top','person','user') }
        }
```

and the final assertion

```powershell
        Should -Invoke Get-ADObject -Exactly -Times 1 -ParameterFilter { $Identity -eq $memberDn }
```

with

```powershell
        Should -Invoke Get-ADObject -Exactly -Times 1 -ParameterFilter { $LDAPFilter -like "*distinguishedName=$memberDn*" }
```

Note: DN values inside LDAP filters are escaped by `New-ExactFilter`/`ConvertTo-LdapFilterValue`; plain alphanumeric test DNs (`CN=Bob Jones,OU=Staff,...`) contain no escapable characters, so `-like` matching on the raw DN works. Keep test DNs free of `( ) * \`.

Add two new tests in the same Describe:

```powershell
    It 'resolves all uncached members of a group in one batched directory search' {
        $groupDn = 'CN=Acme Admins,OU=Groups,DC=corp,DC=example,DC=com'
        $m1 = 'CN=Bob Jones,OU=Staff,DC=corp,DC=example,DC=com'
        $m2 = 'CN=Ann Lee,OU=Staff,DC=corp,DC=example,DC=com'
        Mock -CommandName Get-ADUser -MockWith { @() }
        Mock -CommandName Get-ADOrganizationalUnit -MockWith { @() }
        Mock -CommandName Get-ADGroup -ParameterFilter { $LDAPFilter -like '*name=*Acme**' } -MockWith {
            [pscustomobject]@{ Name='Acme Admins'; DistinguishedName=$groupDn
                description=''; info=''; managedBy=''; member=@($m1, $m2); memberof=@()
                GroupScope='Global'; GroupCategory='Security'; mail=$null; adminCount=$null
                whenCreated=$null; whenChanged=$null }
        }
        Mock -CommandName Get-ADGroup -MockWith { @() }
        Mock -CommandName Get-ADObject -MockWith {
            @(
                [pscustomobject]@{ DistinguishedName=$m1; sAMAccountName='bjones'
                    displayName='Bob Jones'; name='Bob Jones'; objectClass=@('top','person','user') }
                [pscustomobject]@{ DistinguishedName=$m2; sAMAccountName='alee'
                    displayName='Ann Lee'; name='Ann Lee'; objectClass=@('top','person','user') }
            )
        }
        $inp = [pscustomobject]@{
            Users = @(); Keywords = @('Acme'); KnownGroups = @()
            Domains = @([pscustomobject]@{ Domain='corp.example.com'; Server='dc1'; Name='Corp' })
        }
        $data = Get-AdDiscoveryData -InputData $inp
        @($data.Groups[0].MemberDirectoryObjects).Count | Should -Be 2
        Should -Invoke Get-ADObject -Exactly -Times 1
    }
    It 'gives unresolved member DNs an empty-attribute entry instead of dropping them' {
        $groupDn = 'CN=Acme Admins,OU=Groups,DC=corp,DC=example,DC=com'
        $gone = 'CN=Ghost User,OU=Staff,DC=corp,DC=example,DC=com'
        Mock -CommandName Get-ADUser -MockWith { @() }
        Mock -CommandName Get-ADOrganizationalUnit -MockWith { @() }
        Mock -CommandName Get-ADGroup -ParameterFilter { $LDAPFilter -like '*name=*Acme**' } -MockWith {
            [pscustomobject]@{ Name='Acme Admins'; DistinguishedName=$groupDn
                description=''; info=''; managedBy=''; member=@($gone); memberof=@()
                GroupScope='Global'; GroupCategory='Security'; mail=$null; adminCount=$null
                whenCreated=$null; whenChanged=$null }
        }
        Mock -CommandName Get-ADGroup -MockWith { @() }
        Mock -CommandName Get-ADObject -MockWith { @() }   # directory returns nothing
        $inp = [pscustomobject]@{
            Users = @(); Keywords = @('Acme'); KnownGroups = @()
            Domains = @([pscustomobject]@{ Domain='corp.example.com'; Server='dc1'; Name='Corp' })
        }
        $data = Get-AdDiscoveryData -InputData $inp
        $entry = @($data.Groups[0].MemberDirectoryObjects)[0]
        $entry.DistinguishedName | Should -Be $gone
        $entry.SamAccountName | Should -Be ''
        $entry.ObjectClass | Should -Be ''
    }
```

Note the group-search mock now carries `member` inline (search results with heavy props are reused without an identity hydration fetch), so no `$Identity` mock is needed in the new tests.

- [ ] **Step 2: Run to verify the updated/new tests fail**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path ./tests/Get-AdDiscoveryData.Tests.ps1 -Output Detailed"`
Expected: the three touched tests FAIL (current code calls `Get-ADObject -Identity` per member).

- [ ] **Step 3: Implement the batch resolver**

In `src/Ad/Get-AdDiscoveryData.ps1`:

1. Extend the stats table: `$queryStats = @{ GroupSearches = 0; OuSearches = 0; UserSearches = 0; IdentityFetches = 0; MemberFetches = 0; MemberSearches = 0; MemberCacheHits = 0 }`.
2. Replace `function Resolve-AdMemberObject { ... }` with:

```powershell
    function Resolve-AdMemberObjectBatch {
        # Ensures every requested member DN has a cache entry, fetching uncached
        # DNs with OR'd distinguishedName filters (indexed, one round trip per
        # ~1000 DNs) instead of one Get-ADObject per member. DNs the directory
        # does not return (deleted, cross-domain, unreadable) get an
        # empty-attribute entry, matching the old per-DN failure shape.
        param(
            [Parameter(Mandatory)][hashtable]$Common,
            [Parameter(Mandatory)][string]$Domain,
            [string[]]$DistinguishedNames,
            [Parameter(Mandatory)][hashtable]$Cache
        )
        $wanted = New-Object System.Collections.Generic.List[string]
        $requested = @{}
        foreach ($dn in @($DistinguishedNames)) {
            if ([string]::IsNullOrWhiteSpace($dn)) { continue }
            $key = $dn.ToLower()
            if ($Cache.ContainsKey($key)) { $queryStats['MemberCacheHits']++; continue }
            if ($requested.ContainsKey($key)) { continue }
            $requested[$key] = $true
            $wanted.Add($dn)
        }
        if ($wanted.Count -eq 0) { return }

        $clauses = @($wanted | ForEach-Object { New-ExactFilter -Attribute 'distinguishedName' -Value $_ })
        foreach ($batch in Get-LdapClauseBatches -Clauses $clauses) {
            $query = @{} + $Common
            $query['LDAPFilter'] = New-LdapOrFilter -Clauses $batch
            $query['Properties'] = $memberObjectProps
            try {
                $sw = [System.Diagnostics.Stopwatch]::StartNew()
                $found = @(Get-ADObject @query)
                $queryStats['MemberSearches']++
                Write-DiscoveryLog -Level DEBUG -Message ("[{0}] member batch search: {1} of {2} DN(s) resolved in {3} ms, filter {4} chars" -f `
                    $Domain, $found.Count, @($batch).Count, $sw.ElapsedMilliseconds, ([string]$query['LDAPFilter']).Length)
            } catch {
                $found = @()
                Write-DiscoveryLog -Level WARN -Message ("[{0}] member batch search failed: {1}" -f $Domain, $_.Exception.Message)
            }
            foreach ($adObject in $found) {
                if (-not $adObject) { continue }
                $classes = @($adObject.objectClass)
                $objectClass = if ($classes.Count -gt 0) { [string]$classes[-1] } else { '' }
                Add-CachedMemberObject -Cache $Cache -DistinguishedName "$($adObject.DistinguishedName)" `
                    -SamAccountName "$($adObject.sAMAccountName)" -DisplayName "$($adObject.displayName)" `
                    -Name "$($adObject.name)" -ObjectClass $objectClass
            }
        }
        foreach ($dn in $wanted) {
            $queryStats['MemberFetches']++
            $key = $dn.ToLower()
            if (-not $Cache.ContainsKey($key)) {
                $Cache[$key] = [pscustomobject]@{
                    DistinguishedName = $dn; SamAccountName = ''; DisplayName = ''; Name = ''; ObjectClass = ''
                }
            }
        }
    }
```

3. Rework the shaping loop into two passes:

```powershell
        Write-Host "    shaping $($candidateDns.Count) candidate groups..."
        $shapeTimer = [System.Diagnostics.Stopwatch]::StartNew()
        $memberFetchMark  = $queryStats['MemberFetches']
        $memberSearchMark = $queryStats['MemberSearches']
        $memberHitMark    = $queryStats['MemberCacheHits']
        $memberRefCount   = 0
        $domainGroupCount = 0
        $shapedGroups = New-Object System.Collections.Generic.List[object]
        $memberDnsToResolve = New-Object System.Collections.Generic.List[string]
        foreach ($dn in $candidateDns) {
            $group = $hydratedByDn[$dn.ToLower()]
            if (-not $hydratedByDn.ContainsKey($dn.ToLower())) {
                $group = Get-AdGroupByIdentity -Common $ctx.Common -Domain $ctx.Domain -Identity $dn -Properties $groupProps -Warnings $warnings
            }
            if (-not $group) { continue }
            $shapedGroups.Add($group)
            foreach ($memberDn in @($group.member)) {
                if (-not [string]::IsNullOrWhiteSpace($memberDn)) { $memberDnsToResolve.Add($memberDn) }
            }
        }
        Resolve-AdMemberObjectBatch -Common $ctx.Common -Domain $ctx.Domain `
            -DistinguishedNames $memberDnsToResolve.ToArray() -Cache $memberObjectCache
        foreach ($group in $shapedGroups) {
            $memberDirectoryObjects = New-Object System.Collections.Generic.List[object]
            foreach ($memberDn in @($group.member)) {
                if ([string]::IsNullOrWhiteSpace($memberDn)) { continue }
                $memberDirectoryObjects.Add($memberObjectCache[$memberDn.ToLower()])
                $memberRefCount++
            }
            $allGroups.Add([pscustomobject]@{
                Domain = $ctx.Domain; Name = $group.Name; DistinguishedName = $group.DistinguishedName
                Description = $group.description; Info = $group.info; ManagedBy = $group.managedBy
                Member = @($group.member); MemberOf = @($group.memberof)
                MemberDirectoryObjects = $memberDirectoryObjects.ToArray()
                GroupScope = "$($group.GroupScope)"; GroupCategory = "$($group.GroupCategory)"
                Mail = $group.mail; AdminCount = $group.adminCount
                WhenCreated = $group.whenCreated; WhenChanged = $group.whenChanged
            })
            $domainGroupCount++
        }
        Write-DiscoveryLog ("[{0}] shaped {1} group(s) with {2} member reference(s) ({3} DN(s) fetched in {4} search(es), {5} cache hits) in {6} ms" -f `
            $ctx.Domain, $domainGroupCount, $memberRefCount, `
            ($queryStats['MemberFetches'] - $memberFetchMark), ($queryStats['MemberSearches'] - $memberSearchMark), `
            ($queryStats['MemberCacheHits'] - $memberHitMark), $shapeTimer.ElapsedMilliseconds)
```

Behavior note vs. the old code: the old loop skipped `$null` member objects; the batch resolver guarantees an entry per non-blank DN, so `MemberDirectoryObjects` now always matches the non-blank `Member` count — same as before in practice (the old `Resolve-AdMemberObject` never returned `$null` for a non-blank DN either).

4. Update the final "LDAP work" summary line to include searches:

```powershell
    Write-DiscoveryLog ("LDAP work: {0} group searches, {1} OU searches, {2} user searches, {3} identity fetches, {4} member DN fetches in {5} member searches ({6} member cache hits)" -f `
        $queryStats['GroupSearches'], $queryStats['OuSearches'], $queryStats['UserSearches'], `
        $queryStats['IdentityFetches'], $queryStats['MemberFetches'], $queryStats['MemberSearches'], $queryStats['MemberCacheHits'])
```

- [ ] **Step 4: Run AD tests, verify pass**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path ./tests/Get-AdDiscoveryData.Tests.ps1 -Output Detailed"`
Expected: PASS — including the untouched cache-seed tests (`Times 0` Get-ADObject assertions hold: fully cached member lists produce an empty `$wanted`, so no search fires).

- [ ] **Step 5: Full suite, lint, commit**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path ./tests -Output Detailed"` and the ScriptAnalyzer command → green.

```bash
git add src/Ad/Get-AdDiscoveryData.ps1 tests/Get-AdDiscoveryData.Tests.ps1
git commit -m "perf: resolve group members in batched DN searches, not per-DN fetches

Report shaping issued one serial Get-ADObject per uncached member DN
(prod: 28,066 round trips at ~91 ms = 43 min in one domain). Members are
now resolved through OR'd distinguishedName filters via
Get-LdapClauseBatches -- one indexed search per ~1000 DNs -- with
unresolved DNs still receiving the empty-attribute entry the per-DN
failure path produced.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: Resolve members only for engine-kept groups

**Files:**
- Modify: `src/Ad/Get-AdDiscoveryData.ps1` (move member resolution out of the per-domain loop, behind a global engine pre-pass)
- Test: `tests/Get-AdDiscoveryData.Tests.ps1`
- Modify: `CLAUDE.md` (architecture note)

**Interfaces:**
- Consumes: `Resolve-AdMemberObjectBatch` (Task 4), `Find-CandidateGroups`/`Expand-VendorGroupClosure` (already dot-sourced and used by the fetch layer), `$knownKeys`/`$excludeKeys`/`$keywords` (already built at function scope).
- Produces: `Get-AdDiscoveryData` output unchanged in shape; groups the engine scores `None` (and non-known) now carry `MemberDirectoryObjects = @()`. Downstream is safe: `Select-DiscoveryResults` can never select a `None` group, so nothing ever reads member display objects for them.

**Why a GLOBAL pre-pass (not per-domain):** `Expand-VendorGroupClosure` can promote a group in domain A because it contains a vendor group discovered in domain B. A per-domain keep-set would miss that promotion and strip members from a group the real engine later reports. Running the same two engine functions over all domains' groups reproduces the downstream keep-decision exactly.

- [ ] **Step 1: Adjust the nested-group cache-seed test so its parent stays kept (will fail after the change otherwise)**

In `tests/Get-AdDiscoveryData.Tests.ps1`, test `'seeds the member cache with fetched groups so nested group members are never re-queried'`: the parent `Global Stewards` currently scores `None` (its child is only vendor-membership Low, below the closure's Medium seed rank), so after this task it would legitimately get no member objects. Give the child an Owner signal so the parent is promoted and stays kept. In the two `Acme Admins` mocks (`$LDAPFilter -like "*member=$userDn*"` and `$Identity -eq $childDn`), change `managedBy=''` to `managedBy=$userDn`.

- [ ] **Step 2: Add the gating test**

Append inside `Describe 'Get-AdDiscoveryData'`:

```powershell
    It 'skips member resolution for candidates the engine scores None' {
        # A no-signal parent pulled in by the parent lookup must not cost
        # member-resolution searches: the engine can never select it.
        $userDn   = 'CN=John Smith,OU=Vendor,DC=corp,DC=example,DC=com'
        $childDn  = 'CN=Acme Admins,OU=Groups,DC=corp,DC=example,DC=com'
        $parentDn = 'CN=Big Umbrella,OU=Groups,DC=corp,DC=example,DC=com'
        $strangerDn = 'CN=Uncached Stranger,OU=Staff,DC=corp,DC=example,DC=com'
        Mock -CommandName Get-ADObject -MockWith { @() }
        Mock -CommandName Get-ADUser -MockWith {
            [pscustomobject]@{ SamAccountName='jsmith'; DisplayName='John Smith'; GivenName='John'; sn='Smith'
                CN='John Smith'; Name='John Smith'; UserPrincipalName='jsmith@vendor.com'; mail=$null
                DistinguishedName=$userDn; objectSid='S-1-5-21-1-2-3-1001'; memberOf=@() }
        }
        Mock -CommandName Get-ADGroup -ParameterFilter { $LDAPFilter -like "*member=$userDn*" } -MockWith {
            [pscustomobject]@{ Name='Acme Admins'; DistinguishedName=$childDn
                description=''; info=''; managedBy=''; member=@($userDn); memberof=@($parentDn)
                GroupScope='Global'; GroupCategory='Security'; mail=$null; adminCount=$null
                whenCreated=$null; whenChanged=$null }
        }
        Mock -CommandName Get-ADGroup -ParameterFilter { $LDAPFilter -like "*member=$childDn*" } -MockWith {
            [pscustomobject]@{ Name='Big Umbrella'; DistinguishedName=$parentDn
                description=''; info=''; managedBy=''; member=@($childDn, $strangerDn); memberof=@()
                GroupScope='Global'; GroupCategory='Security'; mail=$null; adminCount=$null
                whenCreated=$null; whenChanged=$null }
        }
        Mock -CommandName Get-ADGroup -MockWith { @() }
        $inp = [pscustomobject]@{
            Users       = @([pscustomobject]@{ SamAccountName='jsmith'; DisplayName='John Smith' })
            Keywords    = @()
            KnownGroups = @()
            Domains     = @([pscustomobject]@{ Domain='corp.example.com'; Server='dc1'; Name='Corp' })
        }
        $data = Get-AdDiscoveryData -InputData $inp
        # Child (vendor member -> Low) keeps its member objects...
        $child = $data.Groups | Where-Object { $_.Name -eq 'Acme Admins' }
        @($child.MemberDirectoryObjects).Count | Should -Be 1
        # ...the None-scored umbrella does not, and its unknown member is never fetched.
        $parent = $data.Groups | Where-Object { $_.Name -eq 'Big Umbrella' }
        @($parent.MemberDirectoryObjects).Count | Should -Be 0
        Should -Invoke Get-ADObject -Exactly -Times 0
    }
```

(Child's Low score comes from `MemberVendorUser`; the umbrella's `NestedVendorGroup` needs a Medium+ child seed, and Low is below the closure's seed rank, so the umbrella stays `None`.)

- [ ] **Step 3: Run to verify the new test fails**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path ./tests/Get-AdDiscoveryData.Tests.ps1 -Output Detailed"`
Expected: new test FAILS (`Big Umbrella` currently gets 2 member objects and Get-ADObject fires for the stranger DN).

- [ ] **Step 4: Restructure Get-AdDiscoveryData**

1. In the per-domain shaping section (Task 4's version): delete the `Resolve-AdMemberObjectBatch` call and the member-stat marks; build records with `MemberDirectoryObjects = @()`; collect nothing per-member. The per-domain log line becomes:

```powershell
        Write-DiscoveryLog ("[{0}] shaped {1} group(s) in {2} ms (member resolution deferred to engine pre-pass)" -f `
            $ctx.Domain, $domainGroupCount, $shapeTimer.ElapsedMilliseconds)
```

2. After the domain loop, replace

```powershell
    $groupsArr = $allGroups.ToArray()
    $usersArr  = $vendorUsers.ToArray()
```

with

```powershell
    $groupsArr = $allGroups.ToArray()
    $usersArr  = $vendorUsers.ToArray()

    # Global engine pre-pass: member display objects are needed only for groups
    # the engine can put in a report (any confidence above None, or known).
    # Junk candidates -- no-signal parents from the parent lookup, stray search
    # pulls -- skip member resolution entirely. Global (not per-domain) so
    # cross-domain NestedVendorGroup promotions keep their members.
    $prepass = Find-CandidateGroups -Groups $groupsArr -Keywords $keywords `
        -VendorUsers $usersArr -KnownKeys $knownKeys -ExcludeKeys $excludeKeys
    $prepass = Expand-VendorGroupClosure -Results $prepass
    $keepByDn = @{}
    foreach ($res in @($prepass)) {
        if ($res.IsKnown -or "$($res.Confidence)" -ne 'None') {
            $keepByDn[$res.DistinguishedName.ToLower()] = $true
        }
    }
    foreach ($ctx in $domainContexts) {
        $domainRecords = @($groupsArr | Where-Object {
            $_.Domain -eq $ctx.Domain -and $keepByDn.ContainsKey($_.DistinguishedName.ToLower())
        })
        if ($domainRecords.Count -eq 0) { continue }
        $resolveTimer = [System.Diagnostics.Stopwatch]::StartNew()
        $memberFetchMark  = $queryStats['MemberFetches']
        $memberSearchMark = $queryStats['MemberSearches']
        $memberHitMark    = $queryStats['MemberCacheHits']
        $memberDnsToResolve = New-Object System.Collections.Generic.List[string]
        foreach ($rec in $domainRecords) {
            foreach ($m in @($rec.Member)) {
                if (-not [string]::IsNullOrWhiteSpace($m)) { $memberDnsToResolve.Add($m) }
            }
        }
        Resolve-AdMemberObjectBatch -Common $ctx.Common -Domain $ctx.Domain `
            -DistinguishedNames $memberDnsToResolve.ToArray() -Cache $memberObjectCache
        $memberRefCount = 0
        foreach ($rec in $domainRecords) {
            $memberDirectoryObjects = New-Object System.Collections.Generic.List[object]
            foreach ($m in @($rec.Member)) {
                if ([string]::IsNullOrWhiteSpace($m)) { continue }
                $memberDirectoryObjects.Add($memberObjectCache[$m.ToLower()])
                $memberRefCount++
            }
            $rec.MemberDirectoryObjects = $memberDirectoryObjects.ToArray()
        }
        Write-DiscoveryLog ("[{0}] resolved members for {1} kept group(s): {2} reference(s) ({3} DN(s) fetched in {4} search(es), {5} cache hits) in {6} ms" -f `
            $ctx.Domain, $domainRecords.Count, $memberRefCount, `
            ($queryStats['MemberFetches'] - $memberFetchMark), ($queryStats['MemberSearches'] - $memberSearchMark), `
            ($queryStats['MemberCacheHits'] - $memberHitMark), $resolveTimer.ElapsedMilliseconds)
    }
```

Notes for the implementer:
- `$keywords`, `$knownKeys`, `$excludeKeys` are already defined before the domain loop (built for the trusted-name gating) — no new construction.
- `MemberDirectoryObjects` is a NoteProperty on a `[pscustomobject]`; assigning `$rec.MemberDirectoryObjects = ...` mutates the record in place, which is exactly what downstream consumers of `$groupsArr` see.
- Engine calls use plain assignment per the leading-comma convention (no `@( )` around `Find-CandidateGroups`/`Expand-VendorGroupClosure`).

- [ ] **Step 5: Run the AD tests, then the full suite**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path ./tests/Get-AdDiscoveryData.Tests.ps1 -Output Detailed"`
Expected: PASS, including Step 1's adjusted nested-group test and Step 2's gating test.

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path ./tests -Output Detailed"`
Expected: all green — pay attention to `Fixture.Tests.ps1` (surfaced groups are all kept, so CSV member rows are unchanged) and `Find-VendorAdGroup.Tests.ps1`. If a Find-VendorAdGroup test asserts member output for a `None`-scored mock group, that test is asserting dead behavior — update it to use a group with at least one signal, mirroring Step 1's approach.

- [ ] **Step 6: End-to-end smoke + docs**

Run: `pwsh -NoProfile -File ./tests/fixtures/Show-FixtureDiscovery.ps1`
Expected: same 15 surfaced groups as Task 2, member columns populated.

In `CLAUDE.md`, "Architecture" section, extend the `Ad/` bullet's description: after the sentence about returning a plain data object, add: "Member display objects are resolved after a global engine pre-pass (`Find-CandidateGroups` + `Expand-VendorGroupClosure` over all domains), in batched `distinguishedName` OR-filter searches, and only for groups the engine keeps (confidence above None or known)."

In the "Matching model" section, update the trusted-name sentence to note that `MemberVendorUser` **and** `NestedVendorGroup` do not seed description-name trust.

- [ ] **Step 7: Lint + commit**

Run: `pwsh -NoProfile -Command "Invoke-ScriptAnalyzer -Path . -Recurse -Settings ./PSScriptAnalyzerSettings.psd1"` → clean.

```bash
git add src/Ad/Get-AdDiscoveryData.ps1 tests/Get-AdDiscoveryData.Tests.ps1 CLAUDE.md
git commit -m "perf: resolve member display objects only for engine-kept groups

Shaping paid per-member directory work for every candidate, including
no-signal parents and search junk the engine immediately drops. A global
engine pre-pass (same Find-CandidateGroups + Expand-VendorGroupClosure
the report pipeline runs) now decides which groups can ever be reported,
and only those get member resolution. Global, not per-domain, so
cross-domain NestedVendorGroup promotions keep their member lists.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Expected impact on the prod.example.com profile

| Cost driver | Before | After |
|---|---|---|
| Candidates from "Administrators" description trust | 649 groups + their parents + next-round cascade (→ 1005 total) | 0 (name never trusted); expected total per user estimate: ~160–300 |
| Member resolution | 28,066 serial `Get-ADObject` × ~91 ms ≈ 43 min | kept-groups-only unique DNs, ~1000 per indexed search — expect well under a minute |
| Trusted-name description scans | every trusted name each round, one glued mega-filter per round | far fewer names (Task 1), correctly bounded filters (Task 3) |
| Report noise | Administrators-mention groups at Medium | gone; Administrators itself still surfaces (Medium/High via NestedVendorGroup) — intended |

Not addressed (accepted): the ~55 s unindexed user-token description scan per domain (inherent to `description=*token*` contains-searches; one scan per ~1000 clauses after Task 3), and per-call ADWS session overhead if a domain uses explicit `-Credential` — worth checking the next run's per-search timings in `discovery.log`.
