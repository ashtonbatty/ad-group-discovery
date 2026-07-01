# Vendor User Reports Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add two CSV reports scoped to the vendor users — a normalized user→group membership report and a per-user account-audit report — emitted whenever `Csv` is in `-Formats`.

**Architecture:** Keep the AD boundary thin. `Get-AdDiscoveryData` (the only AD-touching function) gains extra queried user attributes and carries them (plus the user's home `Domain`) on each vendor-user object. Two new **pure** engine functions project that data into report rows; two new **pure** report writers emit hardened CSV. `Find-VendorAdGroup` wires them into the existing `Csv` output block. The fixture is extended so the whole pipeline is testable on Linux `pwsh` with no live AD.

**Tech Stack:** Windows PowerShell 5.1 target, Pester 5 tests, PSScriptAnalyzer lint.

## Global Constraints

- Target **Windows PowerShell 5.1** — no syntax/cmdlets unavailable in 5.1.
- Only `Get-AdDiscoveryData` may call AD cmdlets. All new matching/report logic is pure functions over the discovery-data object.
- All CSV cells go through `Protect-CsvCell` (formula-injection hardening) before `Export-Csv -NoTypeInformation -Encoding UTF8`.
- One `*.Tests.ps1` per new source function, named after the function, under `tests/`.
- New engine functions are called with plain assignment; tests that check `.Count` wrap the call in `@( )`.
- Run the suite with: `pwsh -NoProfile -Command "Invoke-Pester -Path ./tests -Output Detailed"`.
- Lint with: `pwsh -NoProfile -Command "Invoke-ScriptAnalyzer -Path . -Recurse -Settings ./PSScriptAnalyzerSettings.psd1"`.
- Work on branch `feat/vendor-user-reports` (already created; the design spec is committed there).

## File Structure

- Create `src/Engine/Get-DnDomainAndName.ps1` — pure DN parser → `{ Domain; Name }`.
- Create `src/Engine/Get-VendorUserMemberships.ps1` — pure; combined memberOf + discovered-group projection.
- Create `src/Engine/Get-VendorUserAccounts.ps1` — pure; per-user account-audit projection incl. password-expiry FileTime conversion.
- Create `src/Report/Write-UserMembershipReport.ps1` — CSV writer.
- Create `src/Report/Write-UserAccountReport.ps1` — CSV writer.
- Modify `src/Ad/Get-AdDiscoveryData.ps1` — extra user props + `Domain`/audit fields on each vendor user.
- Modify `src/Find-VendorAdGroup.ps1` — emit the two new CSVs in the `Csv` block.
- Modify `tests/fixtures/New-DiscoveryFixture.ps1` + regenerate `tests/fixtures/directory.json` — audit fields on fixture users.
- Modify `tests/fixtures/Import-DiscoveryFixture.ps1` — carry `Domain`, `MemberOf`, and audit fields onto fixture vendor users.
- Modify `tests/Fixture.Tests.ps1` + `tests/fixtures/README.md` — end-to-end assertions + oracle docs.
- Create the four `tests/*.Tests.ps1` files matching the new functions.

---

### Task 1: DN → domain + name parser (`Get-DnDomainAndName`)

**Files:**
- Create: `src/Engine/Get-DnDomainAndName.ps1`
- Test: `tests/Get-DnDomainAndName.Tests.ps1`

**Interfaces:**
- Produces: `Get-DnDomainAndName -DistinguishedName <string>` → `[pscustomobject]@{ Domain=<string>; Name=<string> }`. `Domain` is the `DC=` components joined with `.`; `Name` is the leaf RDN value (CN/OU) with DN escaping removed. Empty strings for a null/blank input.

- [ ] **Step 1: Write the failing test**

Create `tests/Get-DnDomainAndName.Tests.ps1`:

```powershell
BeforeAll { . "$PSScriptRoot/_TestHelpers.ps1" }

Describe 'Get-DnDomainAndName' {
    It 'derives domain from DC components and name from the leaf CN' {
        $r = Get-DnDomainAndName -DistinguishedName 'CN=Sales Team,OU=Groups,DC=corp,DC=example,DC=com'
        $r.Domain | Should -Be 'corp.example.com'
        $r.Name   | Should -Be 'Sales Team'
    }
    It 'unescapes an escaped comma in the leaf RDN' {
        $r = Get-DnDomainAndName -DistinguishedName 'CN=Smith\, John,OU=Groups,DC=corp,DC=example,DC=com'
        $r.Name | Should -Be 'Smith, John'
    }
    It 'returns empty strings for blank input' {
        $r = Get-DnDomainAndName -DistinguishedName ''
        $r.Domain | Should -Be ''
        $r.Name   | Should -Be ''
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path ./tests/Get-DnDomainAndName.Tests.ps1 -Output Detailed"`
Expected: FAIL — `Get-DnDomainAndName` is not recognized.

- [ ] **Step 3: Write minimal implementation**

Create `src/Engine/Get-DnDomainAndName.ps1`:

```powershell
function Get-DnDomainAndName {
    # Parse a distinguished name into its domain (DC components joined with '.')
    # and its leaf object name (the first RDN's value, DN-unescaped). Pure string
    # work: no directory access. Mirrors the unescaped-comma split in
    # Get-OuComponentsFromDn.
    [CmdletBinding()]
    param([string]$DistinguishedName)
    if ([string]::IsNullOrWhiteSpace($DistinguishedName)) {
        return [pscustomobject]@{ Domain = ''; Name = '' }
    }
    $parts = $DistinguishedName -split '(?<!\\),'   # split on unescaped commas
    $name = ''
    if ($parts.Count -gt 0 -and $parts[0].Trim() -match '^(?:CN|OU)=(.+)$') {
        $name = ($Matches[1] -replace '\\(.)', '$1')   # drop DN escape backslashes
    }
    $dcs = @()
    foreach ($p in $parts) {
        $t = $p.Trim()
        if ($t -match '^DC=(.+)$') { $dcs += $Matches[1] }
    }
    [pscustomobject]@{ Domain = ($dcs -join '.'); Name = $name }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path ./tests/Get-DnDomainAndName.Tests.ps1 -Output Detailed"`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add src/Engine/Get-DnDomainAndName.ps1 tests/Get-DnDomainAndName.Tests.ps1
git commit -m "feat: add Get-DnDomainAndName DN parser"
```

---

### Task 2: User→group membership projection (`Get-VendorUserMemberships`)

**Files:**
- Create: `src/Engine/Get-VendorUserMemberships.ps1`
- Test: `tests/Get-VendorUserMemberships.Tests.ps1`

**Interfaces:**
- Consumes: `Get-DnDomainAndName` (Task 1); `New-VendorPrincipalIndex` and `Resolve-VendorPrincipal` (existing engine functions — the latter decodes FSP-SID DNs and plain DNs against the index).
- Produces: `Get-VendorUserMemberships -VendorUsers <object[]> -Groups <object[]>` → rows `[pscustomobject]@{ UserDomain; UserSamAccountName; UserDisplayName; GroupDomain; GroupName }`, deduped per user by group DN, sorted by `UserSamAccountName, GroupDomain, GroupName`. Vendor-user objects are expected to carry `Domain`, `SamAccountName`, `DisplayName`, `Sid`, `DistinguishedName`, `MemberOf`. Group objects carry `Domain`, `Name`, `DistinguishedName`, `Member`.

Combined source (documented in the spec): (b) discovered groups the user belongs to — matched by resolving each group `Member` DN through the vendor-principal index, giving cross-domain (FSP) coverage with authoritative group `Domain`/`Name`; then (a) the user's `memberOf` — all home-domain groups, `Domain`/`Name` derived from each DN. Discovered rows are emitted first so their authoritative names win on dedup.

- [ ] **Step 1: Write the failing test**

Create `tests/Get-VendorUserMemberships.Tests.ps1`:

```powershell
BeforeAll { . "$PSScriptRoot/_TestHelpers.ps1" }

Describe 'Get-VendorUserMemberships' {
    BeforeAll {
        $script:users = @(
            [pscustomobject]@{
                SamAccountName='ohaddad'; DisplayName='Omar Haddad'
                Sid='S-1-5-21-9-9-9-1017'; Domain='dmz.globex.net'
                DistinguishedName='CN=Omar Haddad,OU=Vendors,DC=dmz,DC=globex,DC=net'
                MemberOf=@('CN=Northwind RW,OU=Groups,DC=dmz,DC=globex,DC=net')
            }
        )
        # A cross-domain group in corp where ohaddad is present as a foreign security principal.
        $script:groups = @(
            [pscustomobject]@{
                Domain='corp.globex.com'; Name='NWT Application Owners'
                DistinguishedName='CN=NWT Application Owners,OU=Northwind,OU=Vendors,DC=corp,DC=globex,DC=com'
                Member=@('CN=S-1-5-21-9-9-9-1017,CN=ForeignSecurityPrincipals,DC=corp,DC=globex,DC=com')
            }
        )
    }

    It 'emits a home-domain memberOf row with domain and name derived from the DN' {
        $rows = @(Get-VendorUserMemberships -VendorUsers $script:users -Groups @())
        $home = $rows | Where-Object GroupName -eq 'Northwind RW'
        $home.UserDomain  | Should -Be 'dmz.globex.net'
        $home.GroupDomain | Should -Be 'dmz.globex.net'
        $home.UserSamAccountName | Should -Be 'ohaddad'
    }

    It 'emits a cross-domain row from the discovered-group FSP member side' {
        $rows = @(Get-VendorUserMemberships -VendorUsers $script:users -Groups $script:groups)
        $cross = $rows | Where-Object GroupName -eq 'NWT Application Owners'
        $cross.GroupDomain | Should -Be 'corp.globex.com'
        $cross.UserDomain  | Should -Be 'dmz.globex.net'
    }

    It 'dedups a group seen from both sources, preferring the discovered name' {
        $u = [pscustomobject]@{
            SamAccountName='jbrooks'; DisplayName='Jacob Brooks'
            Sid='S-1-5-21-9-9-9-1001'; Domain='corp.globex.com'
            DistinguishedName='CN=Jacob Brooks,OU=Vendors,DC=corp,DC=globex,DC=com'
            MemberOf=@('CN=NWT Application Owners,OU=Northwind,OU=Vendors,DC=corp,DC=globex,DC=com')
        }
        $g = [pscustomobject]@{
            Domain='corp.globex.com'; Name='NWT Application Owners'
            DistinguishedName='CN=NWT Application Owners,OU=Northwind,OU=Vendors,DC=corp,DC=globex,DC=com'
            Member=@('CN=Jacob Brooks,OU=Vendors,DC=corp,DC=globex,DC=com')
        }
        $rows = @(Get-VendorUserMemberships -VendorUsers @($u) -Groups @($g))
        @($rows | Where-Object GroupName -eq 'NWT Application Owners').Count | Should -Be 1
    }

    It 'returns nothing for a user with no memberships' {
        $u = [pscustomobject]@{ SamAccountName='x'; DisplayName='X'; Sid='S-1-5-21-0-0-0-1'
            Domain='corp.globex.com'; DistinguishedName='CN=X,DC=corp,DC=globex,DC=com'; MemberOf=@() }
        @(Get-VendorUserMemberships -VendorUsers @($u) -Groups @()).Count | Should -Be 0
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path ./tests/Get-VendorUserMemberships.Tests.ps1 -Output Detailed"`
Expected: FAIL — `Get-VendorUserMemberships` is not recognized.

- [ ] **Step 3: Write minimal implementation**

Create `src/Engine/Get-VendorUserMemberships.ps1`:

```powershell
function Get-VendorUserMemberships {
    # Pure projection: one normalized row per (vendor user, group) membership.
    # Combined source so cross-domain memberships are not lost:
    #   (b) discovered groups whose member list resolves to the vendor user (via
    #       real DN or foreign-security-principal SID) -> authoritative Domain/Name,
    #       the only source that sees cross-domain memberships;
    #   (a) the user's memberOf -> all home-domain groups, Domain/Name parsed from DN.
    # Discovered rows win on dedup (authoritative name over DN-derived).
    [CmdletBinding()]
    param([object[]]$VendorUsers, [object[]]$Groups)

    function Get-UserKey {
        param([object]$User)
        if ($User.Sid)               { return 'sid:' + ([string]$User.Sid).ToLower() }
        if ($User.DistinguishedName) { return 'dn:'  + $User.DistinguishedName.ToLower() }
        return 'sam:' + ([string]$User.SamAccountName).ToLower()
    }

    $index = New-VendorPrincipalIndex -VendorUsers $VendorUsers

    # Pre-index discovered groups by the vendor user found in their member list.
    $discoveredByUser = @{}
    foreach ($g in @($Groups)) {
        foreach ($memberDn in @($g.Member)) {
            $matchUser = Resolve-VendorPrincipal -Identity $memberDn -Index $index
            if (-not $matchUser) { continue }
            $key = Get-UserKey -User $matchUser
            if (-not $discoveredByUser.ContainsKey($key)) {
                $discoveredByUser[$key] = New-Object System.Collections.Generic.List[object]
            }
            $discoveredByUser[$key].Add($g)
        }
    }

    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($user in @($VendorUsers)) {
        $seen = @{}   # lowercased group DN -> already emitted for this user
        $userKey = Get-UserKey -User $user

        if ($discoveredByUser.ContainsKey($userKey)) {
            foreach ($g in $discoveredByUser[$userKey]) {
                $dnKey = ([string]$g.DistinguishedName).ToLower()
                if ($seen.ContainsKey($dnKey)) { continue }
                $seen[$dnKey] = $true
                $rows.Add([pscustomobject]@{
                    UserDomain         = $user.Domain
                    UserSamAccountName = $user.SamAccountName
                    UserDisplayName    = $user.DisplayName
                    GroupDomain        = $g.Domain
                    GroupName          = $g.Name
                })
            }
        }

        foreach ($dn in @($user.MemberOf)) {
            if ([string]::IsNullOrWhiteSpace($dn)) { continue }
            $dnKey = $dn.ToLower()
            if ($seen.ContainsKey($dnKey)) { continue }
            $seen[$dnKey] = $true
            $parsed = Get-DnDomainAndName -DistinguishedName $dn
            $rows.Add([pscustomobject]@{
                UserDomain         = $user.Domain
                UserSamAccountName = $user.SamAccountName
                UserDisplayName    = $user.DisplayName
                GroupDomain        = $parsed.Domain
                GroupName          = $parsed.Name
            })
        }
    }

    $rows | Sort-Object UserSamAccountName, GroupDomain, GroupName
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path ./tests/Get-VendorUserMemberships.Tests.ps1 -Output Detailed"`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add src/Engine/Get-VendorUserMemberships.ps1 tests/Get-VendorUserMemberships.Tests.ps1
git commit -m "feat: add Get-VendorUserMemberships projection"
```

---

### Task 3: User account-audit projection (`Get-VendorUserAccounts`)

**Files:**
- Create: `src/Engine/Get-VendorUserAccounts.ps1`
- Test: `tests/Get-VendorUserAccounts.Tests.ps1`

**Interfaces:**
- Produces: `Get-VendorUserAccounts -VendorUsers <object[]>` → one row per user `[pscustomobject]@{ UserDomain; UserSamAccountName; UserDisplayName; Enabled; LockedOut; Description; AccountExpirationDate; LastLogonDate; PasswordLastSet; PasswordExpiry; PasswordNeverExpires; BadLogonCount }`. Date fields are formatted `yyyy-MM-dd HH:mm:ss` (DateTime) or passed through (string), `''` when null. `PasswordExpiry` is derived from the user's `PasswordExpiryComputed` (raw Int64 FileTime): `''` for `0` (must-change), `''` for `Int64.MaxValue` (never — `FromFileTime` throws), otherwise the converted date.
- Consumes: vendor-user objects carrying `Domain, SamAccountName, DisplayName, Enabled, LockedOut, Description, AccountExpirationDate, LastLogonDate, PasswordLastSet, PasswordNeverExpires, BadLogonCount, PasswordExpiryComputed` (populated by Task 6 / the fixture bridge).

- [ ] **Step 1: Write the failing test**

Create `tests/Get-VendorUserAccounts.Tests.ps1`:

```powershell
BeforeAll { . "$PSScriptRoot/_TestHelpers.ps1" }

Describe 'Get-VendorUserAccounts' {
    It 'projects one row per user with the audit fields' {
        $users = @(
            [pscustomobject]@{
                Domain='corp.example.com'; SamAccountName='svc-acme'; DisplayName='ACME Svc'
                Enabled=$true; LockedOut=$false; Description='vendor svc'
                AccountExpirationDate=$null; LastLogonDate=$null; PasswordLastSet=$null
                PasswordNeverExpires=$false; BadLogonCount=0; PasswordExpiryComputed='0'
            }
        )
        $rows = @(Get-VendorUserAccounts -VendorUsers $users)
        $rows.Count | Should -Be 1
        $rows[0].UserSamAccountName | Should -Be 'svc-acme'
        $rows[0].Enabled | Should -Be $true
        $rows[0].Description | Should -Be 'vendor svc'
    }

    It 'blanks PasswordExpiry for the 0 (must-change) sentinel' {
        $users = @([pscustomobject]@{ Domain='c'; SamAccountName='a'; DisplayName='A'
            Enabled=$true; LockedOut=$false; Description=''
            AccountExpirationDate=$null; LastLogonDate=$null; PasswordLastSet=$null
            PasswordNeverExpires=$false; BadLogonCount=0; PasswordExpiryComputed='0' })
        (@(Get-VendorUserAccounts -VendorUsers $users))[0].PasswordExpiry | Should -Be ''
    }

    It 'blanks PasswordExpiry for the Int64.MaxValue (never) sentinel' {
        $users = @([pscustomobject]@{ Domain='c'; SamAccountName='a'; DisplayName='A'
            Enabled=$true; LockedOut=$false; Description=''
            AccountExpirationDate=$null; LastLogonDate=$null; PasswordLastSet=$null
            PasswordNeverExpires=$true; BadLogonCount=0; PasswordExpiryComputed='9223372036854775807' })
        (@(Get-VendorUserAccounts -VendorUsers $users))[0].PasswordExpiry | Should -Be ''
    }

    It 'converts a real FileTime to a formatted date' {
        $ft = '133612200000000000'
        $expected = [datetime]::FromFileTime([int64]$ft).ToString('yyyy-MM-dd HH:mm:ss')
        $users = @([pscustomobject]@{ Domain='c'; SamAccountName='a'; DisplayName='A'
            Enabled=$true; LockedOut=$false; Description=''
            AccountExpirationDate=$null; LastLogonDate=$null; PasswordLastSet=$null
            PasswordNeverExpires=$false; BadLogonCount=0; PasswordExpiryComputed=$ft })
        (@(Get-VendorUserAccounts -VendorUsers $users))[0].PasswordExpiry | Should -Be $expected
    }

    It 'formats a DateTime date field and passes a string date through' {
        $users = @([pscustomobject]@{ Domain='c'; SamAccountName='a'; DisplayName='A'
            Enabled=$true; LockedOut=$false; Description=''
            AccountExpirationDate=[datetime]'2026-12-31T00:00:00'; LastLogonDate='2026-06-29T17:55:10'; PasswordLastSet=$null
            PasswordNeverExpires=$false; BadLogonCount=0; PasswordExpiryComputed=$null })
        $row = (@(Get-VendorUserAccounts -VendorUsers $users))[0]
        $row.AccountExpirationDate | Should -Be '2026-12-31 00:00:00'
        $row.LastLogonDate | Should -Be '2026-06-29T17:55:10'
        $row.PasswordExpiry | Should -Be ''
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path ./tests/Get-VendorUserAccounts.Tests.ps1 -Output Detailed"`
Expected: FAIL — `Get-VendorUserAccounts` is not recognized.

- [ ] **Step 3: Write minimal implementation**

Create `src/Engine/Get-VendorUserAccounts.ps1`:

```powershell
function Get-VendorUserAccounts {
    # Pure projection: one account-audit row per vendor user. Date fields are
    # formatted uniformly; PasswordExpiry is derived from the raw
    # msDS-UserPasswordExpiryTimeComputed FileTime carried as PasswordExpiryComputed.
    [CmdletBinding()]
    param([object[]]$VendorUsers)

    function Format-AccountDate {
        param($Value)
        if ($null -eq $Value) { return '' }
        if ($Value -is [datetime]) { return $Value.ToString('yyyy-MM-dd HH:mm:ss') }
        return [string]$Value
    }

    function Convert-PasswordExpiry {
        param($Raw)
        if ($null -eq $Raw) { return '' }
        $val = [int64]0
        if (-not [int64]::TryParse([string]$Raw, [ref]$val)) { return '' }
        # 0 = expired / must change at next logon; Int64.MaxValue = never
        # (FromFileTime throws on it). Both render as blank.
        if ($val -le 0 -or $val -eq [int64]::MaxValue) { return '' }
        try { return [datetime]::FromFileTime($val).ToString('yyyy-MM-dd HH:mm:ss') } catch { return '' }
    }

    foreach ($user in @($VendorUsers)) {
        [pscustomobject]@{
            UserDomain            = $user.Domain
            UserSamAccountName    = $user.SamAccountName
            UserDisplayName       = $user.DisplayName
            Enabled               = $user.Enabled
            LockedOut             = $user.LockedOut
            Description           = $user.Description
            AccountExpirationDate = (Format-AccountDate $user.AccountExpirationDate)
            LastLogonDate         = (Format-AccountDate $user.LastLogonDate)
            PasswordLastSet       = (Format-AccountDate $user.PasswordLastSet)
            PasswordExpiry        = (Convert-PasswordExpiry $user.PasswordExpiryComputed)
            PasswordNeverExpires  = $user.PasswordNeverExpires
            BadLogonCount         = $user.BadLogonCount
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path ./tests/Get-VendorUserAccounts.Tests.ps1 -Output Detailed"`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add src/Engine/Get-VendorUserAccounts.ps1 tests/Get-VendorUserAccounts.Tests.ps1
git commit -m "feat: add Get-VendorUserAccounts projection"
```

---

### Task 4: Membership CSV writer (`Write-UserMembershipReport`)

**Files:**
- Create: `src/Report/Write-UserMembershipReport.ps1`
- Test: `tests/Write-UserMembershipReport.Tests.ps1`

**Interfaces:**
- Consumes: rows from `Get-VendorUserMemberships` (Task 2); `Protect-CsvCell` (existing).
- Produces: `Write-UserMembershipReport -Rows <object[]> -Path <string>` — writes a CSV with columns `UserDomain, UserSamAccountName, UserDisplayName, GroupDomain, GroupName`, every cell hardened.

- [ ] **Step 1: Write the failing test**

Create `tests/Write-UserMembershipReport.Tests.ps1`:

```powershell
BeforeAll {
    . "$PSScriptRoot/_TestHelpers.ps1"
    $script:tmp = New-TestTempDir -Prefix 'umem'
}
AfterAll { Remove-Item -Recurse -Force $script:tmp -ErrorAction SilentlyContinue }

Describe 'Write-UserMembershipReport' {
    It 'writes one row per membership with the expected columns' {
        $rows = @(
            [pscustomobject]@{ UserDomain='corp'; UserSamAccountName='jbrooks'; UserDisplayName='Jacob Brooks'
                GroupDomain='corp'; GroupName='NWT Application Owners' }
        )
        $path = Join-Path $tmp 'm.csv'
        Write-UserMembershipReport -Rows $rows -Path $path
        $out = @(Import-Csv $path)
        $out.Count | Should -Be 1
        $out[0].UserSamAccountName | Should -Be 'jbrooks'
        $out[0].GroupName | Should -Be 'NWT Application Owners'
        ($out[0].PSObject.Properties.Name) | Should -Be @('UserDomain','UserSamAccountName','UserDisplayName','GroupDomain','GroupName')
    }
    It 'hardens a formula-injection group name' {
        $rows = @([pscustomobject]@{ UserDomain='corp'; UserSamAccountName='a'; UserDisplayName='A'
            GroupDomain='corp'; GroupName='=cmd()' })
        $path = Join-Path $tmp 'inj.csv'
        Write-UserMembershipReport -Rows $rows -Path $path
        (@(Import-Csv $path))[0].GroupName | Should -Be "'=cmd()"
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path ./tests/Write-UserMembershipReport.Tests.ps1 -Output Detailed"`
Expected: FAIL — `Write-UserMembershipReport` is not recognized.

- [ ] **Step 3: Write minimal implementation**

Create `src/Report/Write-UserMembershipReport.ps1`:

```powershell
function Write-UserMembershipReport {
    # Normalized user->group membership CSV. Group metadata is
    # attacker-influenceable, so every cell is formula-injection hardened.
    [CmdletBinding()]
    param([object[]]$Rows, [Parameter(Mandatory)][string]$Path)
    $out = foreach ($r in @($Rows)) {
        [pscustomobject]@{
            UserDomain         = (Protect-CsvCell $r.UserDomain)
            UserSamAccountName = (Protect-CsvCell $r.UserSamAccountName)
            UserDisplayName    = (Protect-CsvCell $r.UserDisplayName)
            GroupDomain        = (Protect-CsvCell $r.GroupDomain)
            GroupName          = (Protect-CsvCell $r.GroupName)
        }
    }
    $out | Export-Csv -LiteralPath $Path -NoTypeInformation -Encoding UTF8
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path ./tests/Write-UserMembershipReport.Tests.ps1 -Output Detailed"`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add src/Report/Write-UserMembershipReport.ps1 tests/Write-UserMembershipReport.Tests.ps1
git commit -m "feat: add Write-UserMembershipReport CSV writer"
```

---

### Task 5: Account-audit CSV writer (`Write-UserAccountReport`)

**Files:**
- Create: `src/Report/Write-UserAccountReport.ps1`
- Test: `tests/Write-UserAccountReport.Tests.ps1`

**Interfaces:**
- Consumes: rows from `Get-VendorUserAccounts` (Task 3); `Protect-CsvCell` (existing).
- Produces: `Write-UserAccountReport -Rows <object[]> -Path <string>` — writes a CSV with columns `UserDomain, UserSamAccountName, UserDisplayName, Enabled, LockedOut, Description, AccountExpirationDate, LastLogonDate, PasswordLastSet, PasswordExpiry, PasswordNeverExpires, BadLogonCount`, every cell hardened.

- [ ] **Step 1: Write the failing test**

Create `tests/Write-UserAccountReport.Tests.ps1`:

```powershell
BeforeAll {
    . "$PSScriptRoot/_TestHelpers.ps1"
    $script:tmp = New-TestTempDir -Prefix 'uacc'
}
AfterAll { Remove-Item -Recurse -Force $script:tmp -ErrorAction SilentlyContinue }

Describe 'Write-UserAccountReport' {
    It 'writes one row per account with the expected columns' {
        $rows = @(
            [pscustomobject]@{ UserDomain='corp'; UserSamAccountName='jdoe'; UserDisplayName='John Doe'
                Enabled=$true; LockedOut=$true; Description='contractor'
                AccountExpirationDate='2026-12-31 00:00:00'; LastLogonDate='2026-06-29 17:55:10'
                PasswordLastSet='2026-05-18 08:03:44'; PasswordExpiry='2026-08-16 08:03:44'
                PasswordNeverExpires=$false; BadLogonCount=5 }
        )
        $path = Join-Path $tmp 'a.csv'
        Write-UserAccountReport -Rows $rows -Path $path
        $out = @(Import-Csv $path)
        $out.Count | Should -Be 1
        $out[0].UserSamAccountName | Should -Be 'jdoe'
        $out[0].LockedOut | Should -Be 'True'
        $out[0].BadLogonCount | Should -Be '5'
        ($out[0].PSObject.Properties.Name) | Should -Be @('UserDomain','UserSamAccountName','UserDisplayName','Enabled','LockedOut','Description','AccountExpirationDate','LastLogonDate','PasswordLastSet','PasswordExpiry','PasswordNeverExpires','BadLogonCount')
    }
    It 'hardens a formula-injection description' {
        $rows = @([pscustomobject]@{ UserDomain='corp'; UserSamAccountName='a'; UserDisplayName='A'
            Enabled=$true; LockedOut=$false; Description='=HYPERLINK()'
            AccountExpirationDate=''; LastLogonDate=''; PasswordLastSet=''; PasswordExpiry=''
            PasswordNeverExpires=$false; BadLogonCount=0 })
        $path = Join-Path $tmp 'inj.csv'
        Write-UserAccountReport -Rows $rows -Path $path
        (@(Import-Csv $path))[0].Description | Should -Be "'=HYPERLINK()"
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path ./tests/Write-UserAccountReport.Tests.ps1 -Output Detailed"`
Expected: FAIL — `Write-UserAccountReport` is not recognized.

- [ ] **Step 3: Write minimal implementation**

Create `src/Report/Write-UserAccountReport.ps1`:

```powershell
function Write-UserAccountReport {
    # Per-user account-audit CSV. User attributes (e.g. Description) are
    # attacker-influenceable, so every cell is formula-injection hardened.
    [CmdletBinding()]
    param([object[]]$Rows, [Parameter(Mandatory)][string]$Path)
    $out = foreach ($r in @($Rows)) {
        [pscustomobject]@{
            UserDomain            = (Protect-CsvCell $r.UserDomain)
            UserSamAccountName    = (Protect-CsvCell $r.UserSamAccountName)
            UserDisplayName       = (Protect-CsvCell $r.UserDisplayName)
            Enabled               = (Protect-CsvCell $r.Enabled)
            LockedOut             = (Protect-CsvCell $r.LockedOut)
            Description           = (Protect-CsvCell $r.Description)
            AccountExpirationDate = (Protect-CsvCell $r.AccountExpirationDate)
            LastLogonDate         = (Protect-CsvCell $r.LastLogonDate)
            PasswordLastSet       = (Protect-CsvCell $r.PasswordLastSet)
            PasswordExpiry        = (Protect-CsvCell $r.PasswordExpiry)
            PasswordNeverExpires  = (Protect-CsvCell $r.PasswordNeverExpires)
            BadLogonCount         = (Protect-CsvCell $r.BadLogonCount)
        }
    }
    $out | Export-Csv -LiteralPath $Path -NoTypeInformation -Encoding UTF8
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path ./tests/Write-UserAccountReport.Tests.ps1 -Output Detailed"`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add src/Report/Write-UserAccountReport.ps1 tests/Write-UserAccountReport.Tests.ps1
git commit -m "feat: add Write-UserAccountReport CSV writer"
```

---

### Task 6: Carry Domain + audit fields on vendor users (`Get-AdDiscoveryData`)

**Files:**
- Modify: `src/Ad/Get-AdDiscoveryData.ps1` (`$userProps` at line 13; vendor-user object at lines 284-292)
- Test: `tests/Get-AdDiscoveryData.Tests.ps1` (add assertions)

**Interfaces:**
- Produces: each object in `$data.VendorUsers` additionally carries `Domain` (the domain it was resolved in = home domain, kept by SID dedup) and `Enabled, LockedOut, Description, AccountExpirationDate, LastLogonDate, PasswordLastSet, BadLogonCount, PasswordNeverExpires, PasswordExpiryComputed` (from `msDS-UserPasswordExpiryTimeComputed`). Existing fields unchanged.

- [ ] **Step 1: Write the failing test**

Add these two `It` blocks inside the `Describe 'Get-AdDiscoveryData'` block in `tests/Get-AdDiscoveryData.Tests.ps1` (e.g. after the existing `'loads groups and resolves vendor users for a domain'` test). The first uses the `Describe`-level `Mock -CommandName Get-ADUser` — extend that mock to return the new fields (edit the existing `BeforeAll` mock at lines 21-26 to add the audit properties shown):

Extend the existing `Get-ADUser` mock (lines 21-26) to:

```powershell
        Mock -CommandName Get-ADUser -MockWith {
            [pscustomobject]@{ SamAccountName='jsmith'; DisplayName='John Smith'; GivenName='John'; sn='Smith'
                CN='John Smith'; Name='John Smith'; UserPrincipalName='jsmith@vendor.com'; mail='jsmith@vendor.com'
                DistinguishedName='CN=John Smith,OU=Vendor,DC=corp,DC=example,DC=com'
                objectSid='S-1-5-21-1-2-3-1001'
                Enabled=$true; LockedOut=$false; Description='vendor account'
                AccountExpirationDate=$null; LastLogonDate=$null; PasswordLastSet=$null
                BadLogonCount=0; PasswordNeverExpires=$false; 'msDS-UserPasswordExpiryTimeComputed'='0' }
        }
```

Add the test:

```powershell
    It 'records the home domain and audit fields on each vendor user' {
        $discoveryInput = [pscustomobject]@{
            Users   = @([pscustomobject]@{ SamAccountName='jsmith'; DisplayName='John Smith' })
            Domains = @([pscustomobject]@{ Domain='corp.example.com'; Server='dc1'; Name='Corp' })
        }
        $data = Get-AdDiscoveryData -InputData $discoveryInput
        $data.VendorUsers[0].Domain | Should -Be 'corp.example.com'
        $data.VendorUsers[0].Description | Should -Be 'vendor account'
        $data.VendorUsers[0].Enabled | Should -Be $true
        ($data.VendorUsers[0].PSObject.Properties.Name) | Should -Contain 'PasswordExpiryComputed'
    }
```

Add the home-domain dedup assertion (the same physical SID resolved in the first-queried domain must keep that domain):

```powershell
    It 'keeps the first-resolved (home) domain when the same SID appears in a later domain' {
        Mock -CommandName Get-ADGroup -MockWith { @() }
        Mock -CommandName Get-ADUser -MockWith {
            [pscustomobject]@{ SamAccountName='jsmith'; DisplayName='John Smith'; GivenName='John'; sn='Smith'
                CN='John Smith'; Name='John Smith'; UserPrincipalName='jsmith@corp.example.com'; mail=$null
                DistinguishedName='CN=John Smith,DC=corp,DC=example,DC=com'
                objectSid='S-1-5-21-7-7-7-1001'
                Enabled=$true; LockedOut=$false; Description=''
                AccountExpirationDate=$null; LastLogonDate=$null; PasswordLastSet=$null
                BadLogonCount=0; PasswordNeverExpires=$false; 'msDS-UserPasswordExpiryTimeComputed'='0' }
        }
        $inp = [pscustomobject]@{
            Users   = @([pscustomobject]@{ SamAccountName='jsmith'; DisplayName='John Smith' })
            Domains = @(
                [pscustomobject]@{ Domain='corp.example.com';    Server='corp.example.com';    Name='Corp' }
                [pscustomobject]@{ Domain='partner.example.com'; Server='partner.example.com'; Name='Partner' }
            )
        }
        $data = Get-AdDiscoveryData -InputData $inp
        $data.VendorUsers.Count | Should -Be 1
        $data.VendorUsers[0].Domain | Should -Be 'corp.example.com'
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path ./tests/Get-AdDiscoveryData.Tests.ps1 -Output Detailed"`
Expected: FAIL — `Domain` / `Description` / `PasswordExpiryComputed` are absent on the vendor-user objects.

- [ ] **Step 3: Write minimal implementation**

In `src/Ad/Get-AdDiscoveryData.ps1`, replace the `$userProps` line (line 13):

```powershell
    $userProps  = @('displayName','givenName','sn','cn','name','userPrincipalName','mail','objectSid','memberOf',
                    'enabled','lockedOut','description','accountExpirationDate','lastLogonDate',
                    'passwordLastSet','badLogonCount','passwordNeverExpires','msDS-UserPasswordExpiryTimeComputed')
```

Then in the vendor-user object (lines 284-292), add the new properties so the block reads:

```powershell
                $vendorUsers.Add([pscustomobject]@{
                    SamAccountName    = $u.SamAccountName
                    DisplayName       = if ($u.displayName) { $u.displayName } else { $u.Name }
                    Mail              = $u.mail
                    Sid               = $sid
                    DistinguishedName = $u.DistinguishedName
                    MemberOf          = @($u.memberOf)
                    Tokens            = $tokens
                    Domain            = $d.Domain
                    Enabled           = $u.Enabled
                    LockedOut         = $u.LockedOut
                    Description       = $u.Description
                    AccountExpirationDate = $u.AccountExpirationDate
                    LastLogonDate     = $u.LastLogonDate
                    PasswordLastSet   = $u.PasswordLastSet
                    BadLogonCount     = $u.BadLogonCount
                    PasswordNeverExpires   = $u.PasswordNeverExpires
                    PasswordExpiryComputed = $u.'msDS-UserPasswordExpiryTimeComputed'
                })
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path ./tests/Get-AdDiscoveryData.Tests.ps1 -Output Detailed"`
Expected: PASS (all existing tests plus the 2 new ones).

- [ ] **Step 5: Commit**

```bash
git add src/Ad/Get-AdDiscoveryData.ps1 tests/Get-AdDiscoveryData.Tests.ps1
git commit -m "feat: carry home domain and account-audit fields on vendor users"
```

---

### Task 7: Wire the new reports into `Find-VendorAdGroup`

**Files:**
- Modify: `src/Find-VendorAdGroup.ps1` (inside the `if ($Formats -contains 'Csv')` block, lines 45-49)
- Test: `tests/Find-VendorAdGroup.Tests.ps1` (add assertions)

**Interfaces:**
- Consumes: `Get-VendorUserMemberships`, `Get-VendorUserAccounts`, `Write-UserMembershipReport`, `Write-UserAccountReport` (Tasks 2-5); `$data.VendorUsers` (with Task 6 fields) and `$groups`.
- Produces: writes `vendor-user-memberships.csv` and `vendor-user-accounts.csv` into `$OutputDirectory` whenever `Csv` is selected.

- [ ] **Step 1: Write the failing test**

In `tests/Find-VendorAdGroup.Tests.ps1`, extend the `Describe`-level `Mock -CommandName Get-AdDiscoveryData` (lines 14-28) so its `VendorUsers` is non-empty and one user is a member of the mocked group. Replace the mock body with:

```powershell
        Mock -CommandName Get-AdDiscoveryData -MockWith {
            [pscustomobject]@{
                Groups = @(
                    [pscustomobject]@{ Domain='corp.example.com'; Name='Acme Admins'
                        DistinguishedName='CN=Acme Admins,OU=Groups,DC=corp,DC=example,DC=com'
                        Description='Acme app'; Info=''; ManagedBy=''
                        Member=@('CN=John Smith,OU=Vendor,DC=corp,DC=example,DC=com'); MemberOf=@()
                        GroupScope='Global'; GroupCategory='Security'; Mail=$null; AdminCount=$null
                        WhenCreated=$null; WhenChanged=$null }
                )
                VendorUsers   = @(
                    [pscustomobject]@{ SamAccountName='jsmith'; DisplayName='John Smith'
                        Sid='S-1-5-21-1-2-3-1001'; Domain='corp.example.com'
                        DistinguishedName='CN=John Smith,OU=Vendor,DC=corp,DC=example,DC=com'
                        MemberOf=@('CN=Acme Admins,OU=Groups,DC=corp,DC=example,DC=com')
                        Enabled=$true; LockedOut=$false; Description='vendor'
                        AccountExpirationDate=$null; LastLogonDate=$null; PasswordLastSet=$null
                        BadLogonCount=0; PasswordNeverExpires=$false; PasswordExpiryComputed='0' }
                )
                DnIndex       = @{}
                FailedDomains = @()
                Warnings      = @()
            }
        }
```

Add the test:

```powershell
    It 'writes the user membership and account CSV reports' {
        $out = Join-Path $tmp 'user-reports'
        Find-VendorAdGroup -UsersCsv "$tmp/users.csv" -DomainsCsv "$tmp/domains.csv" `
            -KeywordsCsv "$tmp/keywords.csv" -KnownGroupsCsv "$tmp/known.csv" -ExcludeGroupsCsv "$tmp/exclude.csv" `
            -OutputDirectory $out -Formats @('Csv')
        Test-Path (Join-Path $out 'vendor-user-memberships.csv') | Should -BeTrue
        Test-Path (Join-Path $out 'vendor-user-accounts.csv') | Should -BeTrue
        $mem = @(Import-Csv (Join-Path $out 'vendor-user-memberships.csv'))
        ($mem | Where-Object { $_.UserSamAccountName -eq 'jsmith' -and $_.GroupName -eq 'Acme Admins' }) | Should -Not -BeNullOrEmpty
        $acc = @(Import-Csv (Join-Path $out 'vendor-user-accounts.csv'))
        ($acc | Where-Object UserSamAccountName -eq 'jsmith').Enabled | Should -Be 'True'
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path ./tests/Find-VendorAdGroup.Tests.ps1 -Output Detailed"`
Expected: FAIL — the two new CSV files do not exist.

- [ ] **Step 3: Write minimal implementation**

In `src/Find-VendorAdGroup.ps1`, replace the `Csv` block (lines 45-49) with:

```powershell
    if ($Formats -contains 'Csv') {
        Write-CsvReport -Results $selected `
            -Path (Join-Path $OutputDirectory 'vendor-group-discovery.csv') `
            -MembersPath (Join-Path $OutputDirectory 'vendor-group-discovery-members.csv')

        $memberships = Get-VendorUserMemberships -VendorUsers $data.VendorUsers -Groups $groups
        Write-UserMembershipReport -Rows $memberships `
            -Path (Join-Path $OutputDirectory 'vendor-user-memberships.csv')

        $accounts = Get-VendorUserAccounts -VendorUsers $data.VendorUsers
        Write-UserAccountReport -Rows $accounts `
            -Path (Join-Path $OutputDirectory 'vendor-user-accounts.csv')
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path ./tests/Find-VendorAdGroup.Tests.ps1 -Output Detailed"`
Expected: PASS (existing tests plus the new one).

- [ ] **Step 5: Commit**

```bash
git add src/Find-VendorAdGroup.ps1 tests/Find-VendorAdGroup.Tests.ps1
git commit -m "feat: emit vendor user membership and account CSVs from Find-VendorAdGroup"
```

---

### Task 8: Extend the fixture and add end-to-end assertions

**Files:**
- Modify: `tests/fixtures/New-DiscoveryFixture.ps1` (user object + per-user overrides)
- Regenerate: `tests/fixtures/directory.json` (by running the generator)
- Modify: `tests/fixtures/Import-DiscoveryFixture.ps1` (carry `Domain`, `MemberOf`, audit fields onto vendor users)
- Modify: `tests/Fixture.Tests.ps1` (assert the two new CSVs)
- Modify: `tests/fixtures/README.md` (document the new reports in the oracle)

**Interfaces:**
- Consumes: everything from Tasks 1-7.
- Produces: a fixture whose vendor users carry `Domain`, `MemberOf`, and audit fields, so `Get-VendorUserMemberships` / `Get-VendorUserAccounts` run end-to-end against it; deterministic oracle values for the assertions below.

- [ ] **Step 1: Add audit fields to the fixture generator**

In `tests/fixtures/New-DiscoveryFixture.ps1`, add audit fields to the user object literal (inside the `$users = foreach ($r in $userRows)` loop, in the `[pscustomobject]@{ ... }` at lines 101-112) so it also contains:

```powershell
        Enabled                = $true
        LockedOut              = $false
        Description            = "$org contractor account"
        AccountExpirationDate  = $null
        LastLogonDate          = '2024-10-01T09:00:00'
        PasswordLastSet        = '2024-06-01T09:00:00'
        PasswordNeverExpires   = $false
        BadLogonCount          = 0
        PasswordExpiryComputed = '133612200000000000'
```

Then, immediately after the `$users = foreach (...) { ... }` block completes (after line 115), add deterministic per-user overrides for the account-report oracle:

```powershell
# Deterministic overrides so the account-audit report has stable, meaningful oracle rows.
($userBySam['gbell']).Enabled = $false                              # disabled account
($userBySam['vreyes']).LockedOut = $true
($userBySam['vreyes']).BadLogonCount = 7                            # locked account with bad logons
($userBySam['npetrova']).PasswordNeverExpires = $true
($userBySam['npetrova']).PasswordExpiryComputed = '9223372036854775807'   # never -> blank in report
```

- [ ] **Step 2: Regenerate the fixture directory**

Run: `pwsh -NoProfile -File ./tests/fixtures/New-DiscoveryFixture.ps1`
Expected: prints `Fixture written: ...directory.json` and `users=40 groups=20 domains=4`. `git diff --stat tests/fixtures/directory.json` should show only additions of the new user fields.

- [ ] **Step 3: Carry the new fields onto fixture vendor users**

In `tests/fixtures/Import-DiscoveryFixture.ps1`, first build a home-domain memberOf map from the directory groups. Insert this immediately before the `$vendorUsers = foreach ($u in $dir.Users) {` line (currently line 43):

```powershell
    # Reverse-index: user DN -> DNs of groups whose member list contains that user DN.
    # This mirrors AD's memberOf (home-domain direct memberships only; cross-domain
    # members appear as FSP SIDs, not the user's DN, so they are excluded here).
    $memberOfByUserDn = @{}
    foreach ($g in $dir.Groups) {
        foreach ($m in @($g.Member)) {
            $k = ([string]$m).ToLower()
            if (-not $memberOfByUserDn.ContainsKey($k)) {
                $memberOfByUserDn[$k] = New-Object System.Collections.Generic.List[string]
            }
            $memberOfByUserDn[$k].Add($g.DistinguishedName)
        }
    }
```

Then, in the `$vendorUsers = foreach ($u in $dir.Users) { ... }` loop, extend the emitted `[pscustomobject]@{ ... }` (lines 47-54) so it also carries the new fields:

```powershell
        [pscustomobject]@{
            SamAccountName    = $u.SamAccountName
            DisplayName       = $u.DisplayName
            Mail              = $u.Mail
            Sid               = $u.Sid
            DistinguishedName = $u.DistinguishedName
            Tokens            = $tokens
            Domain            = $u.Domain
            MemberOf          = @($memberOfByUserDn[$u.DistinguishedName.ToLower()])
            Enabled           = $u.Enabled
            LockedOut         = $u.LockedOut
            Description       = $u.Description
            AccountExpirationDate = $u.AccountExpirationDate
            LastLogonDate     = $u.LastLogonDate
            PasswordLastSet   = $u.PasswordLastSet
            BadLogonCount     = $u.BadLogonCount
            PasswordNeverExpires   = $u.PasswordNeverExpires
            PasswordExpiryComputed = $u.PasswordExpiryComputed
        }
```

Note: `@($memberOfByUserDn[$key])` yields `@()` when the key is absent (indexing a hashtable with a missing key returns `$null`, and `@($null)` is an empty array).

- [ ] **Step 4: Write the failing end-to-end assertions**

In `tests/Fixture.Tests.ps1`, inside the `Describe 'Fixture: public Find-VendorAdGroup (Northwind discovery)'` block, load the new CSVs in its `BeforeAll` (after line 121, the existing `$script:html = ...` line):

```powershell
        $script:userMemberships = @(Import-Csv (Join-Path $script:outDir 'vendor-user-memberships.csv'))
        $script:userAccounts    = @(Import-Csv (Join-Path $script:outDir 'vendor-user-accounts.csv'))
```

Then add these `It` blocks in the same `Describe`:

```powershell
    It 'writes an account row for each of the 20 vendor users' {
        $script:userAccounts.Count | Should -Be 20
    }

    It 'reflects the disabled and locked oracle accounts' {
        ($script:userAccounts | Where-Object UserSamAccountName -eq 'gbell').Enabled | Should -Be 'False'
        $vreyes = $script:userAccounts | Where-Object UserSamAccountName -eq 'vreyes'
        $vreyes.LockedOut | Should -Be 'True'
        $vreyes.BadLogonCount | Should -Be '7'
    }

    It 'blanks PasswordExpiry for the never-expires oracle account' {
        $np = $script:userAccounts | Where-Object UserSamAccountName -eq 'npetrova'
        $np.PasswordNeverExpires | Should -Be 'True'
        $np.PasswordExpiry | Should -Be ''
    }

    It 'includes a cross-domain membership row (FSP member of a group in another domain)' {
        # Omar Haddad (dmz) is a foreign-security-principal member of NWT Application Owners (corp).
        $row = $script:userMemberships | Where-Object {
            $_.UserSamAccountName -eq 'ohaddad' -and $_.GroupName -eq 'NWT Application Owners'
        }
        $row | Should -Not -BeNullOrEmpty
        $row.UserDomain  | Should -Be 'dmz.globex.net'
        $row.GroupDomain | Should -Be 'corp.globex.com'
    }

    It 'includes a home-domain memberOf row' {
        $row = $script:userMemberships | Where-Object {
            $_.UserSamAccountName -eq 'ohaddad' -and $_.GroupName -eq 'Northwind RW'
        }
        $row | Should -Not -BeNullOrEmpty
        $row.GroupDomain | Should -Be 'dmz.globex.net'
    }
```

- [ ] **Step 5: Run test to verify it fails, then passes**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path ./tests/Fixture.Tests.ps1 -Output Detailed"`
Expected before Steps 1-3 are complete: FAIL (missing files/fields). After Steps 1-4: PASS.

- [ ] **Step 6: Document the new reports in the fixture README oracle**

In `tests/fixtures/README.md`, add a short section titled `## User reports` documenting: (1) the account report emits one row per vendor user with the oracle overrides — `gbell` disabled, `vreyes` locked with `BadLogonCount=7`, `npetrova` never-expires (blank `PasswordExpiry`); (2) the membership report is combined memberOf + discovered-group side, and `ohaddad` has a cross-domain row for `NWT Application Owners` (corp) plus a home-domain row for `Northwind RW` (dmz). Keep it consistent with the assertions in `Fixture.Tests.ps1`.

- [ ] **Step 7: Run the full suite and lint**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path ./tests -Output Detailed"`
Expected: all tests pass.

Run: `pwsh -NoProfile -Command "Invoke-ScriptAnalyzer -Path . -Recurse -Settings ./PSScriptAnalyzerSettings.psd1"`
Expected: no new warnings/errors from the added files.

- [ ] **Step 8: Commit**

```bash
git add tests/fixtures/New-DiscoveryFixture.ps1 tests/fixtures/directory.json tests/fixtures/Import-DiscoveryFixture.ps1 tests/Fixture.Tests.ps1 tests/fixtures/README.md
git commit -m "test: extend fixture with vendor user reports and end-to-end assertions"
```

---

## Self-Review

**Spec coverage:**
- Account report fields (active/locked/description/expiry/last login/last pwd change/bad login count/pwd expiry) → Task 3 (`Get-VendorUserAccounts`) + Task 6 (data). ✓
- Membership report normalized columns + combined source + cross-domain via FSP → Task 2 (`Get-VendorUserMemberships`) + Task 1 (DN parse). ✓
- Home-domain `Domain` on vendor users + dedup guarantee → Task 6 (impl + test). ✓
- CSV only, `Protect-CsvCell` hardening → Tasks 4 & 5. ✓
- Always emit with `Csv` format, no new params → Task 7. ✓
- Fixture + tests + README oracle (per CLAUDE.md) → Task 8. ✓
- `msDS-UserPasswordExpiryTimeComputed` sentinel guards (`0`, `Int64.MaxValue`) → Task 3 (impl + tests). ✓
- `GroupName` = leaf CN → Task 1. ✓

**Placeholder scan:** none — every code step contains full code; every run step has a command and expected result.

**Type consistency:** `Get-DnDomainAndName` returns `{Domain; Name}` (used in Task 2). Membership rows use `UserDomain, UserSamAccountName, UserDisplayName, GroupDomain, GroupName` consistently across Tasks 2, 4, 7, 8. Account rows use the 12-column set consistently across Tasks 3, 5, 7, 8. Vendor-user field names (`Domain, Enabled, LockedOut, Description, AccountExpirationDate, LastLogonDate, PasswordLastSet, BadLogonCount, PasswordNeverExpires, PasswordExpiryComputed`) match between Task 6 (producer), Task 3 (consumer), and Task 8 (fixture bridge). ✓
