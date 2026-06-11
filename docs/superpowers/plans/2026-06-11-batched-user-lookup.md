# Batched Vendor-User Lookup + `-MaxIterations` Removal Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the D×U per-user-per-domain `Get-ADUser` queries with one OR'd `-LDAPFilter` query per domain (chunked at 200), and remove the unused `-MaxIterations` parameter from the public API.

**Architecture:** A new pure helper `src/Ad/New-SamLdapFilter.ps1` builds RFC 4515-escaped LDAP filters; `Get-AdDiscoveryData` validates CSV users once, indexes them by sam, and issues chunked batched queries per domain with per-domain failure warnings. SID dedupe and the emitted object shapes are unchanged, so nothing downstream of the AD adapter changes. `-MaxIterations` is dropped from runner → orchestrator → engine; `Expand-VendorGroupClosure` keeps its internal default-25 backstop.

**Tech Stack:** Windows PowerShell 5.1-compatible PowerShell, Pester 5, PSScriptAnalyzer. Spec: `docs/superpowers/specs/2026-06-11-batched-user-lookup-design.md`.

**Conventions that matter here:**
- Tests dot-source all of `src/` via `tests/_TestHelpers.ps1`; AD cmdlets are stubbed there so Pester `Mock` can intercept them on Linux.
- Run the suite with: `pwsh -NoProfile -Command "Invoke-Pester -Path ./tests -Output Detailed"` from the repo root (`/var/home/ashton/dev/misc/powershell/ad-group-discovery`).
- Only `Get-AdDiscoveryData` may call AD cmdlets. New logic that doesn't touch AD must be a pure function.

---

### Task 1: `New-SamLdapFilter` helper (RFC 4515 escaping + OR filter builder)

**Files:**
- Create: `tests/New-SamLdapFilter.Tests.ps1`
- Create: `src/Ad/New-SamLdapFilter.ps1`

- [ ] **Step 1: Write the failing tests**

Create `tests/New-SamLdapFilter.Tests.ps1`:

```powershell
BeforeAll { . "$PSScriptRoot/_TestHelpers.ps1" }

Describe 'ConvertTo-LdapFilterValue' {
    It 'escapes backslash before its own escape sequences' {
        # '\*' must become '\5c\2a', not '\5c5c\2a' or '\5c\5c2a'
        ConvertTo-LdapFilterValue -Value '\*' | Should -Be '\5c\2a'
    }
    It 'escapes asterisk' {
        ConvertTo-LdapFilterValue -Value 'a*b' | Should -Be 'a\2ab'
    }
    It 'escapes parentheses' {
        ConvertTo-LdapFilterValue -Value '(x)' | Should -Be '\28x\29'
    }
    It 'escapes NUL' {
        ConvertTo-LdapFilterValue -Value "a`0b" | Should -Be 'a\00b'
    }
    It 'neutralizes a combined hostile payload' {
        ConvertTo-LdapFilterValue -Value '*)(uid=*))(|(uid=*' |
            Should -Be '\2a\29\28uid=\2a\29\29\28|\28uid=\2a'
    }
    It 'passes an ordinary sam through unchanged' {
        ConvertTo-LdapFilterValue -Value 'j.smith-01' | Should -Be 'j.smith-01'
    }
    It 'accepts an empty string' {
        ConvertTo-LdapFilterValue -Value '' | Should -Be ''
    }
}

Describe 'New-SamLdapFilter' {
    It 'wraps multiple names in an OR clause' {
        New-SamLdapFilter -SamAccountNames @('adoe','jsmith') |
            Should -Be '(|(sAMAccountName=adoe)(sAMAccountName=jsmith))'
    }
    It 'emits a bare clause for a single name' {
        New-SamLdapFilter -SamAccountNames @('jsmith') | Should -Be '(sAMAccountName=jsmith)'
    }
    It 'escapes each value' {
        New-SamLdapFilter -SamAccountNames @('a*','b\') |
            Should -Be '(|(sAMAccountName=a\2a)(sAMAccountName=b\5c))'
    }
    It 'returns an empty string for empty input' {
        New-SamLdapFilter -SamAccountNames @() | Should -Be ''
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path ./tests/New-SamLdapFilter.Tests.ps1 -Output Detailed"`
Expected: all tests FAIL with `CommandNotFoundException` (`ConvertTo-LdapFilterValue` / `New-SamLdapFilter` not recognized).

- [ ] **Step 3: Implement the helper**

Create `src/Ad/New-SamLdapFilter.ps1`:

```powershell
function ConvertTo-LdapFilterValue {
    # RFC 4515 escaping for a value embedded in an LDAP search filter.
    # Backslash must be escaped first or it would re-escape the other sequences.
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)
    $escaped = $Value -replace '\\', '\5c'
    $escaped = $escaped -replace '\*', '\2a'
    $escaped = $escaped -replace '\(', '\28'
    $escaped = $escaped -replace '\)', '\29'
    $escaped -replace "`0", '\00'
}

function New-SamLdapFilter {
    # Builds an OR'd sAMAccountName LDAP filter for a batch of names.
    param([Parameter(Mandatory)][AllowEmptyCollection()][string[]]$SamAccountNames)
    $clauses = @(foreach ($s in $SamAccountNames) {
        "(sAMAccountName=$(ConvertTo-LdapFilterValue -Value $s))"
    })
    if ($clauses.Count -eq 0) { return '' }
    if ($clauses.Count -eq 1) { return $clauses[0] }
    "(|$($clauses -join ''))"
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path ./tests/New-SamLdapFilter.Tests.ps1 -Output Detailed"`
Expected: 11 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add tests/New-SamLdapFilter.Tests.ps1 src/Ad/New-SamLdapFilter.ps1
git commit -m "feat: add RFC 4515 LDAP filter builder for batched sam lookups"
```

---

### Task 2: Batched user lookup in `Get-AdDiscoveryData`

**Files:**
- Modify: `tests/_TestHelpers.ps1:39-45` (AD cmdlet stubs)
- Modify: `tests/Get-AdDiscoveryData.Tests.ps1`
- Modify: `src/Ad/Get-AdDiscoveryData.ps1:40-67` (user-resolution loop)

- [ ] **Step 1: Give the AD stubs real parameters**

The stubs in `tests/_TestHelpers.ps1` currently swallow everything via `ValueFromRemainingArguments`. The new tests filter mock invocations on `$LDAPFilter`, which needs the parameter to actually bind. Replace lines 39–45 (the two stub blocks) with:

```powershell
# Stub AD cmdlets so Pester Mock can intercept them on non-Windows / no-AD test runners.
# Parameters mirror the RSAT cmdlets' (subset we use) so Mock -ParameterFilter can bind them.
if (-not (Get-Command Get-ADGroup  -ErrorAction SilentlyContinue)) {
    function Get-ADGroup  {
        [CmdletBinding()]
        param($Filter, [string]$LDAPFilter, [string[]]$Properties, [string]$Server,
              [System.Management.Automation.PSCredential]$Credential)
    }
}
if (-not (Get-Command Get-ADUser   -ErrorAction SilentlyContinue)) {
    function Get-ADUser   {
        [CmdletBinding()]
        param($Filter, [string]$LDAPFilter, [string[]]$Properties, [string]$Server,
              [System.Management.Automation.PSCredential]$Credential)
    }
}
```

- [ ] **Step 2: Add the failing tests for batching behavior**

In `tests/Get-AdDiscoveryData.Tests.ps1`, inside `Describe 'Get-AdDiscoveryData'`, add these `It` blocks after the existing ones:

```powershell
    It 'issues one batched LDAP query per domain regardless of user count' {
        Mock -CommandName Get-ADGroup -MockWith { @() }
        Mock -CommandName Get-ADUser  -MockWith { @() }
        $inp = [pscustomobject]@{
            Users   = @(
                [pscustomobject]@{ SamAccountName='adoe';   DisplayName='A Doe' }
                [pscustomobject]@{ SamAccountName='jsmith'; DisplayName='J Smith' }
                [pscustomobject]@{ SamAccountName='kchan';  DisplayName='K Chan' }
            )
            Domains = @(
                [pscustomobject]@{ Domain='corp.example.com';    Server='dc1'; Name='Corp' }
                [pscustomobject]@{ Domain='partner.example.com'; Server='dc2'; Name='Partner' }
            )
        }
        $null = Get-AdDiscoveryData -InputData $inp
        Should -Invoke Get-ADUser -Exactly -Times 2
    }
    It 'builds a sorted OR filter over all valid sams' {
        Mock -CommandName Get-ADGroup -MockWith { @() }
        Mock -CommandName Get-ADUser  -MockWith { @() }
        $inp = [pscustomobject]@{
            Users   = @(
                [pscustomobject]@{ SamAccountName='jsmith'; DisplayName='J Smith' }
                [pscustomobject]@{ SamAccountName='adoe';   DisplayName='A Doe' }
            )
            Domains = @([pscustomobject]@{ Domain='corp.example.com'; Server='dc1'; Name='Corp' })
        }
        $null = Get-AdDiscoveryData -InputData $inp
        Should -Invoke Get-ADUser -Exactly -Times 1 -ParameterFilter {
            $LDAPFilter -eq '(|(sAMAccountName=adoe)(sAMAccountName=jsmith))'
        }
    }
    It 'chunks the batched query above the batch size' {
        Mock -CommandName Get-ADGroup -MockWith { @() }
        Mock -CommandName Get-ADUser  -MockWith { @() }
        $users = 1..201 | ForEach-Object {
            [pscustomobject]@{ SamAccountName=('u{0:d3}' -f $_); DisplayName="U$_" }
        }
        $inp = [pscustomobject]@{
            Users   = @($users)
            Domains = @([pscustomobject]@{ Domain='corp.example.com'; Server='dc1'; Name='Corp' })
        }
        $null = Get-AdDiscoveryData -InputData $inp
        Should -Invoke Get-ADUser -Exactly -Times 2
    }
    It 'warns per domain (not per user) when the batched user lookup fails' {
        Mock -CommandName Get-ADGroup -MockWith { @() }
        Mock -CommandName Get-ADUser  -MockWith { throw 'ldap down' }
        $inp = [pscustomobject]@{
            Users   = @(
                [pscustomobject]@{ SamAccountName='adoe';   DisplayName='A Doe' }
                [pscustomobject]@{ SamAccountName='jsmith'; DisplayName='J Smith' }
            )
            Domains = @([pscustomobject]@{ Domain='corp.example.com'; Server='dc1'; Name='Corp' })
        }
        $data = Get-AdDiscoveryData -InputData $inp
        $data.VendorUsers.Count | Should -Be 0
        @($data.Warnings | Where-Object { $_ -match "User lookup failed in 'corp.example.com'" }).Count |
            Should -Be 1
        # A user-lookup failure is not a failed domain (that is reserved for group enumeration).
        $data.FailedDomains.Count | Should -Be 0
    }
    It 'warns once total (not per domain) for a suspicious SamAccountName' {
        Mock -CommandName Get-ADGroup -MockWith { @() }
        Mock -CommandName Get-ADUser  -MockWith { @() }
        $inp = [pscustomobject]@{
            Users   = @([pscustomobject]@{ SamAccountName="evil') -or (cn=*"; DisplayName='X' })
            Domains = @(
                [pscustomobject]@{ Domain='corp.example.com';    Server='dc1'; Name='Corp' }
                [pscustomobject]@{ Domain='partner.example.com'; Server='dc2'; Name='Partner' }
            )
        }
        $data = Get-AdDiscoveryData -InputData $inp
        @($data.Warnings | Where-Object { $_ -match 'suspicious' }).Count | Should -Be 1
        Should -Invoke Get-ADUser -Exactly -Times 0
    }
```

- [ ] **Step 3: Run the file to verify the new tests fail**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path ./tests/Get-AdDiscoveryData.Tests.ps1 -Output Detailed"`
Expected: the 5 existing tests PASS; the 5 new tests FAIL (per-user querying means wrong invocation counts, no `LDAPFilter` parameter, per-user warning text, and two suspicious warnings).

- [ ] **Step 4: Rewrite the user-resolution path in `Get-AdDiscoveryData`**

In `src/Ad/Get-AdDiscoveryData.ps1`:

(a) After the `$userProps` line, add the batch-size constant:

```powershell
    $samBatchSize = 200   # names per OR'd -LDAPFilter; keeps each filter well under LDAP size limits
```

(b) After the `$sidSeen = @{}` line (before the domain loop), add the one-time validation and index:

```powershell
    # Validate CSV users once (not per domain) and index them by sam so batched
    # query results can be mapped back to their CSV row for token building.
    $csvUserBySam = @{}   # PowerShell hashtable: string keys are case-insensitive
    foreach ($csvUser in $InputData.Users) {
        $sam = $csvUser.SamAccountName
        if ([string]::IsNullOrWhiteSpace($sam)) { continue }
        if ($sam -match "['()*\\/]") {
            $warnings.Add("Skipping user with suspicious SamAccountName '$sam'")
            continue
        }
        if (-not $csvUserBySam.ContainsKey($sam)) { $csvUserBySam[$sam] = $csvUser }
    }
    $validSams = @($csvUserBySam.Keys | Sort-Object)   # deterministic filter strings
```

(c) Replace the entire `foreach ($csvUser in $InputData.Users) { ... }` block inside the domain loop (currently lines 40–67) with:

```powershell
        for ($i = 0; $i -lt $validSams.Count; $i += $samBatchSize) {
            $last = [Math]::Min($i + $samBatchSize, $validSams.Count) - 1
            $batchFilter = New-SamLdapFilter -SamAccountNames $validSams[$i..$last]
            try {
                $found = @(Get-ADUser @common -LDAPFilter $batchFilter -Properties $userProps)
            } catch {
                $warnings.Add("User lookup failed in '$($d.Domain)': $($_.Exception.Message)")
                continue
            }
            foreach ($u in $found) {
                if (-not $u) { continue }
                $csvUser = $csvUserBySam["$($u.SamAccountName)"]
                if (-not $csvUser) { continue }   # directory returned a sam we did not ask for
                $sid = "$($u.objectSid)"
                if ($sid -and $sidSeen.ContainsKey($sid)) { continue }   # same physical user already resolved
                if ($sid) { $sidSeen[$sid] = $true }
                $tokens = ConvertTo-IdentityTokens -SamAccountName $u.SamAccountName -DisplayName $u.displayName `
                    -GivenName $u.givenName -Surname $u.sn -Cn $u.cn -Name $u.name `
                    -Upn $u.userPrincipalName -Mail $u.mail -CsvDisplayName $csvUser.DisplayName
                $vendorUsers.Add([pscustomobject]@{
                    SamAccountName = $u.SamAccountName
                    DisplayName    = if ($u.displayName) { $u.displayName } else { $u.Name }
                    Sid            = $sid
                    DistinguishedName = $u.DistinguishedName
                    Tokens         = $tokens
                })
            }
        }
```

Everything else in the function (group enumeration, the trailing `[pscustomobject]` return) is unchanged.

- [ ] **Step 5: Run the file to verify all tests pass**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path ./tests/Get-AdDiscoveryData.Tests.ps1 -Output Detailed"`
Expected: all 10 tests PASS (5 existing + 5 new). If the pre-existing `'resolves two users with the same SamAccountName from different domains independently'` test fails, the `$Server` parameter is not binding in the mock filter — re-check Step 1's stub signature.

- [ ] **Step 6: Run the full suite**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path ./tests -Output Detailed"`
Expected: PASS. The fixture integration tests bypass the AD adapter and must be untouched by this change.

- [ ] **Step 7: Commit**

```bash
git add tests/_TestHelpers.ps1 tests/Get-AdDiscoveryData.Tests.ps1 src/Ad/Get-AdDiscoveryData.ps1
git commit -m "perf: batch per-domain user lookups into OR'd LDAP filters"
```

---

### Task 3: Remove `-MaxIterations` from the public API

**Files:**
- Modify: `Find-VendorAdGroup.ps1:21` (root runner)
- Modify: `src/Find-VendorAdGroup.ps1:12,31` (module function)
- Modify: `src/Engine/Invoke-DiscoveryEngine.ps1:13,22`
- Modify: `README.md:34`

`Expand-VendorGroupClosure` keeps its `$MaxIterations = 25` parameter — it is internal (not exported) and serves as the loop backstop; `tests/Expand-VendorGroupClosure.Tests.ps1` exercises it directly and stays as-is.

- [ ] **Step 1: Remove the parameter from all three public/orchestration layers**

In `Find-VendorAdGroup.ps1` (root runner), delete the line:

```powershell
    [int]$MaxIterations,
```

In `src/Find-VendorAdGroup.ps1`, delete the line:

```powershell
        [int]$MaxIterations = 25,
```

and change the `Invoke-DiscoveryEngine` call from:

```powershell
    $selected = Invoke-DiscoveryEngine -Groups $groups -InputData $inputData `
        -VendorUsers $data.VendorUsers -DnIndex $data.DnIndex `
        -MinimumConfidence $MinimumConfidence -MaxIterations $MaxIterations
```

to:

```powershell
    $selected = Invoke-DiscoveryEngine -Groups $groups -InputData $inputData `
        -VendorUsers $data.VendorUsers -DnIndex $data.DnIndex `
        -MinimumConfidence $MinimumConfidence
```

In `src/Engine/Invoke-DiscoveryEngine.ps1`, change the last two param entries from:

```powershell
        [ValidateSet('Low','Medium','High','Confirmed')][string]$MinimumConfidence = 'Low',
        [int]$MaxIterations = 25
```

to:

```powershell
        [ValidateSet('Low','Medium','High','Confirmed')][string]$MinimumConfidence = 'Low'
```

and the closure call from:

```powershell
    $candidates = Expand-VendorGroupClosure -Results $candidates -MaxIterations $MaxIterations
```

to:

```powershell
    $candidates = Expand-VendorGroupClosure -Results $candidates
```

- [ ] **Step 2: Update the README options line**

In `README.md`, change:

```markdown
Options: `-Formats Csv,Html,Console`, `-Credential`, `-MaxIterations 25`,
`-SecurityGroupsOnly`, `-MinimumConfidence Low|Medium|High|Confirmed`.
```

to:

```markdown
Options: `-Formats Csv,Html,Console`, `-Credential`,
`-SecurityGroupsOnly`, `-MinimumConfidence Low|Medium|High|Confirmed`.
```

- [ ] **Step 3: Verify no public reference remains and the suite passes**

Run: `grep -rn "MaxIterations" --include="*.ps1" --include="*.psm1" --include="*.psd1" --include="*.md" . | grep -v docs/`
Expected: hits only in `src/Engine/Expand-VendorGroupClosure.ps1` and `tests/Expand-VendorGroupClosure.Tests.ps1`.

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path ./tests -Output Detailed"`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add Find-VendorAdGroup.ps1 src/Find-VendorAdGroup.ps1 src/Engine/Invoke-DiscoveryEngine.ps1 README.md
git commit -m "refactor: remove -MaxIterations from the public API"
```

---

### Task 4: Final verification + close out the findings doc

**Files:**
- Modify: `docs/2026-06-10-simplify-skipped-findings.md`

- [ ] **Step 1: Run lint and the smoke test**

Run: `pwsh -NoProfile -Command "Invoke-ScriptAnalyzer -Path . -Recurse -Settings ./PSScriptAnalyzerSettings.psd1"`
Expected: no new findings (compare against a clean run if unsure: it was clean at `491acfa`).

Run: `pwsh -NoProfile -File ./tests/fixtures/Show-FixtureDiscovery.ps1`
Expected: the fixture discovery summary renders without errors.

- [ ] **Step 2: Mark both findings as done in the findings doc**

In `docs/2026-06-10-simplify-skipped-findings.md`:

Under `### Batch the per-user-per-domain ``Get-ADUser`` queries`, append a final list item:

```markdown
- **Status:** Done 2026-06-11 — see
  `docs/superpowers/specs/2026-06-11-batched-user-lookup-design.md` and
  `src/Ad/New-SamLdapFilter.ps1`. Not yet validated against a live directory;
  sanity-check resolved-user counts and warnings on the first multi-domain run.
```

Under `### Remove ``-MaxIterations`` from the public API`, append a final list item:

```markdown
- **Status:** Done 2026-06-11 — removed from the public chain; the internal
  backstop remains on `Expand-VendorGroupClosure`.
```

- [ ] **Step 3: Commit**

```bash
git add docs/2026-06-10-simplify-skipped-findings.md
git commit -m "docs: mark batched-lookup and MaxIterations findings as done"
```
