# AD Vendor Group Audit Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a PowerShell 5.1 tool that audits Active Directory across multiple domains to discover the groups belonging to or used by a vendor, and produces CSV / HTML / console reports with confidence-scored match reasons.

**Architecture:** Modular pipeline. A thin AD adapter (the only code calling `Get-AD*`) bulk-loads groups per domain and resolves vendor-user identities. A set of *pure* engine functions match each group against the known patterns, score confidence, and iterate nested-group membership to closure. Swappable report writers consume one common result shape. The pure engine is unit-tested with Pester without a live directory.

**Tech Stack:** PowerShell 5.1 (dev/test runs fine under pwsh 7.6), RSAT ActiveDirectory module, Pester 5, PSScriptAnalyzer.

---

## Conventions used throughout

- **Target runtime is PowerShell 5.1.** Avoid 7-only syntax: no `??`, no `?.`, no ternary `a ? b : c`, no `-and`-chaining nuances beyond 5.1. `Get-AD*` cmdlets are only ever called inside `src/Ad/`.
- **Pure functions** return PSCustomObjects; they never call `Get-AD*` or touch the filesystem.
- **Case-insensitive matching:** PowerShell `-eq`, `-like`, `-ieq`, `-match`, `-contains` are case-insensitive by default. Hashtable keys are case-sensitive, so DN/key hashtables always store **lowercased** keys.
- **Run tests with:** `Invoke-Pester -Path <file> -Output Detailed` (or `-CI` for exit codes). Every test file begins with `BeforeAll { . "$PSScriptRoot/_TestHelpers.ps1" }`, which dot-sources all of `src/`.
- **Commit after every task** once its tests pass.

## Data contracts (referenced by multiple tasks)

**Normalized input** (from `Read-AuditInput`):
```
[pscustomobject]@{
  Users         = @( [pscustomobject]@{ SamAccountName='jsmith'; DisplayName='John Smith' } )
  Domains       = @( [pscustomobject]@{ Domain='corp.example.com'; Server='dc1.corp.example.com'; Name='Corp' } )
  Keywords      = @('Acme','ACME Corp')
  KnownGroups   = @( [pscustomobject]@{ Domain='corp.example.com'; Identity='Acme Admins' } )
  ExcludeGroups = @( [pscustomobject]@{ Domain='corp.example.com'; Identity='Domain Users' } )
}
```

**Vendor user** (after AD resolution):
```
[pscustomobject]@{
  SamAccountName    = 'jsmith'
  DisplayName       = 'John Smith'
  Sid               = 'S-1-5-21-111-222-333-1001'
  DistinguishedName = 'CN=John Smith,OU=Vendor,DC=corp,DC=example,DC=com'
  Tokens            = @('jsmith','John Smith','John, John'...)   # >=3 chars, unique
}
```

**Group** (from adapter; tests use synthetic objects of this shape):
```
[pscustomobject]@{
  Domain='corp.example.com'; Name='Acme Admins'
  DistinguishedName='CN=Acme Admins,OU=Groups,DC=corp,DC=example,DC=com'
  Description='Owned by jsmith'; Info=''; ManagedBy='CN=John Smith,OU=Vendor,DC=corp,DC=example,DC=com'
  Member=@('CN=...'); MemberOf=@('CN=...')
  GroupScope='Global'; GroupCategory='Security'; Mail=$null; AdminCount=$null
  WhenCreated=[datetime]'2020-01-01'; WhenChanged=[datetime]'2021-01-01'
}
```

**Match reason:** `[pscustomobject]@{ Pattern='NameKeyword'; Value='Acme' }`

**Result object** (per group, produced by `Find-CandidateGroups`, enriched later): all Group fields **plus** `Reasons` (match-reason[]), `Score` (int), `Confidence` ('Confirmed'|'High'|'Medium'|'Low'|'None'), `IsKnown` (bool), `Source` ('Known'|'Discovered'). After `Resolve-ResultDisplay`: adds `Owner` (string), `Members` (string[], vendor members prefixed `*`), `MemberOfDisplay` (string[]).

**Pattern weights** (defined in `Get-MatchConfidence`): `NameKeyword=3, ContainerKeyword=3, Owner=3, DescriptionUser=2, DescriptionKeyword=2, NestedVendorGroup=2, MemberVendorUser=1` (member contribution capped at 3). Banding: `Confirmed` if known; else `High` ≥3, `Medium` =2, `Low` =1, `None` =0.

---

## Task 1: Project scaffolding

**Files:**
- Create: `AdVendorGroupAudit.psm1`
- Create: `AdVendorGroupAudit.psd1`
- Create: `PSScriptAnalyzerSettings.psd1`
- Create: `tests/_TestHelpers.ps1`
- Create: `tests/Scaffolding.Tests.ps1`
- Create: `samples/.gitkeep`, `src/.gitkeep`

- [ ] **Step 1: Create the module loader** `AdVendorGroupAudit.psm1`

```powershell
# Dot-source every function under src/, then export the public entry point.
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Get-ChildItem -Path (Join-Path $here 'src') -Recurse -Filter '*.ps1' -ErrorAction SilentlyContinue |
    ForEach-Object { . $_.FullName }
Export-ModuleMember -Function 'Invoke-AdVendorGroupAudit'
```

- [ ] **Step 2: Create the manifest** `AdVendorGroupAudit.psd1`

```powershell
@{
    RootModule        = 'AdVendorGroupAudit.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = '9d3f5b62-1a4e-4c77-9b2a-0a1f2e3d4c50'
    Author            = 'Ashton Batty'
    Description       = 'Audit AD groups belonging to or used by a vendor across multiple domains.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @('Invoke-AdVendorGroupAudit')
}
```

- [ ] **Step 3: Create analyzer settings** `PSScriptAnalyzerSettings.psd1`

```powershell
@{
    Severity    = @('Error','Warning')
    ExcludeRules = @('PSUseShouldProcessForStateChangingFunctions')
}
```

- [ ] **Step 4: Create the test helper** `tests/_TestHelpers.ps1`

```powershell
# Dot-source all source functions so tests can call them directly (no module import needed).
$root = Split-Path -Parent $PSScriptRoot
Get-ChildItem -Path (Join-Path $root 'src') -Recurse -Filter '*.ps1' -ErrorAction SilentlyContinue |
    ForEach-Object { . $_.FullName }
```

- [ ] **Step 5: Write the scaffolding test** `tests/Scaffolding.Tests.ps1`

```powershell
BeforeAll { . "$PSScriptRoot/_TestHelpers.ps1" }

Describe 'Scaffolding' {
    It 'has a module manifest that parses' {
        $root = Split-Path -Parent $PSScriptRoot
        $manifest = Join-Path $root 'AdVendorGroupAudit.psd1'
        Test-Path $manifest | Should -BeTrue
        { Import-PowerShellDataFile -Path $manifest } | Should -Not -Throw
    }
}
```

- [ ] **Step 6: Ensure Pester 5 is available, then run the test**

Run:
```bash
pwsh -NoProfile -Command "if (-not (Get-Module -ListAvailable Pester | Where-Object Version -ge '5.0')) { Install-Module Pester -Scope CurrentUser -Force -SkipPublisherCheck }; Invoke-Pester -Path ./tests/Scaffolding.Tests.ps1 -Output Detailed"
```
Expected: 1 test passes.

- [ ] **Step 7: Commit**

```bash
git add AdVendorGroupAudit.psm1 AdVendorGroupAudit.psd1 PSScriptAnalyzerSettings.psd1 tests/ samples/ src/
git commit -m "feat: scaffold AdVendorGroupAudit module and test harness"
```

---

## Task 2: Read-AuditInput (input layer)

**Files:**
- Create: `src/Input/Read-AuditInput.ps1`
- Test: `tests/Read-AuditInput.Tests.ps1`

- [ ] **Step 1: Write the failing test**

```powershell
BeforeAll {
    . "$PSScriptRoot/_TestHelpers.ps1"
    $script:tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("audit_" + [guid]::NewGuid())
    New-Item -ItemType Directory -Path $script:tmp | Out-Null
    Set-Content "$tmp/users.csv"        "SamAccountName,DisplayName`njsmith,John Smith"
    Set-Content "$tmp/domains.csv"      "Domain,Server,Name`ncorp.example.com,dc1,Corp"
    Set-Content "$tmp/keywords.csv"     "Keyword`nAcme"
    Set-Content "$tmp/known.csv"        "Domain,Identity`ncorp.example.com,Acme Admins"
    Set-Content "$tmp/exclude.csv"      "Domain,Identity`ncorp.example.com,Domain Users"
}
AfterAll { Remove-Item -Recurse -Force $script:tmp -ErrorAction SilentlyContinue }

Describe 'Read-AuditInput' {
    It 'reads all five CSVs into a normalized object' {
        $r = Read-AuditInput -UsersCsv "$tmp/users.csv" -DomainsCsv "$tmp/domains.csv" `
            -KeywordsCsv "$tmp/keywords.csv" -KnownGroupsCsv "$tmp/known.csv" -ExcludeGroupsCsv "$tmp/exclude.csv"
        $r.Users[0].SamAccountName | Should -Be 'jsmith'
        $r.Domains[0].Domain       | Should -Be 'corp.example.com'
        $r.Keywords                | Should -Contain 'Acme'
        $r.KnownGroups[0].Identity | Should -Be 'Acme Admins'
        $r.ExcludeGroups[0].Identity | Should -Be 'Domain Users'
    }

    It 'throws a clear error when a required file is missing' {
        { Read-AuditInput -UsersCsv "$tmp/nope.csv" -DomainsCsv "$tmp/domains.csv" `
            -KeywordsCsv "$tmp/keywords.csv" -KnownGroupsCsv "$tmp/known.csv" -ExcludeGroupsCsv "$tmp/exclude.csv" } |
            Should -Throw '*not found*'
    }

    It 'throws when the users CSV lacks SamAccountName' {
        Set-Content "$tmp/bad.csv" "Foo`nbar"
        { Read-AuditInput -UsersCsv "$tmp/bad.csv" -DomainsCsv "$tmp/domains.csv" `
            -KeywordsCsv "$tmp/keywords.csv" -KnownGroupsCsv "$tmp/known.csv" -ExcludeGroupsCsv "$tmp/exclude.csv" } |
            Should -Throw '*SamAccountName*'
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path ./tests/Read-AuditInput.Tests.ps1 -Output Detailed"`
Expected: FAIL — `Read-AuditInput` not recognized.

- [ ] **Step 3: Write the implementation** `src/Input/Read-AuditInput.ps1`

```powershell
function Read-AuditInput {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$UsersCsv,
        [Parameter(Mandatory)][string]$DomainsCsv,
        [Parameter(Mandatory)][string]$KeywordsCsv,
        [Parameter(Mandatory)][string]$KnownGroupsCsv,
        [Parameter(Mandatory)][string]$ExcludeGroupsCsv
    )

    function Read-Csv([string]$Path, [string[]]$Required) {
        if (-not (Test-Path -LiteralPath $Path)) { throw "Input file not found: $Path" }
        $rows = @(Import-Csv -LiteralPath $Path)
        if ($rows.Count -gt 0) {
            $cols = $rows[0].PSObject.Properties.Name
            foreach ($c in $Required) {
                if ($cols -notcontains $c) { throw "File '$Path' is missing required column '$c'." }
            }
        }
        return $rows
    }

    $users    = Read-Csv $UsersCsv        @('SamAccountName')
    $domains  = Read-Csv $DomainsCsv      @('Domain')
    $keywords = Read-Csv $KeywordsCsv     @('Keyword')
    $known    = Read-Csv $KnownGroupsCsv  @('Domain','Identity')
    $exclude  = Read-Csv $ExcludeGroupsCsv @('Domain','Identity')

    [pscustomobject]@{
        Users         = $users
        Domains       = $domains
        Keywords      = @($keywords | ForEach-Object { $_.Keyword } | Where-Object { $_ -and $_.Trim() })
        KnownGroups   = $known
        ExcludeGroups = $exclude
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path ./tests/Read-AuditInput.Tests.ps1 -Output Detailed"`
Expected: 3 tests pass.

- [ ] **Step 5: Commit**

```bash
git add src/Input/Read-AuditInput.ps1 tests/Read-AuditInput.Tests.ps1
git commit -m "feat: add Read-AuditInput with validation"
```

---

## Task 3: ConvertTo-IdentityTokens

**Files:**
- Create: `src/Ad/ConvertTo-IdentityTokens.ps1`
- Test: `tests/ConvertTo-IdentityTokens.Tests.ps1`

- [ ] **Step 1: Write the failing test**

```powershell
BeforeAll { . "$PSScriptRoot/_TestHelpers.ps1" }

Describe 'ConvertTo-IdentityTokens' {
    It 'builds unique tokens from AD attributes plus CSV display name' {
        $t = ConvertTo-IdentityTokens -SamAccountName 'jsmith' -DisplayName 'John Smith' `
            -GivenName 'John' -Surname 'Smith' -Cn 'John Smith' -Name 'John Smith' `
            -Upn 'jsmith@vendor.com' -Mail 'jsmith@vendor.com' -CsvDisplayName 'J. Smith'
        $t | Should -Contain 'jsmith'
        $t | Should -Contain 'John Smith'
        $t | Should -Contain 'Smith, John'
        $t | Should -Contain 'J. Smith'
    }

    It 'drops empty and very short (<3 char) tokens' {
        $t = ConvertTo-IdentityTokens -SamAccountName 'ab' -DisplayName 'Al' -Cn 'Alan Bee'
        $t | Should -Not -Contain 'ab'
        $t | Should -Not -Contain 'Al'
        $t | Should -Contain 'Alan Bee'
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path ./tests/ConvertTo-IdentityTokens.Tests.ps1 -Output Detailed"`
Expected: FAIL — function not recognized.

- [ ] **Step 3: Write the implementation** `src/Ad/ConvertTo-IdentityTokens.ps1`

```powershell
function ConvertTo-IdentityTokens {
    [CmdletBinding()]
    param(
        [string]$SamAccountName, [string]$DisplayName, [string]$GivenName, [string]$Surname,
        [string]$Cn, [string]$Name, [string]$Upn, [string]$Mail, [string]$CsvDisplayName
    )
    $tokens = New-Object System.Collections.Generic.List[string]
    foreach ($v in @($SamAccountName, $DisplayName, $Cn, $Name, $Upn, $Mail, $CsvDisplayName)) {
        if ($v) { $tokens.Add($v) }
    }
    if ($GivenName -and $Surname) {
        $tokens.Add("$GivenName $Surname")
        $tokens.Add("$Surname, $GivenName")
        $tokens.Add("$Surname $GivenName")
    }
    @($tokens | Where-Object { $_ -and $_.Trim().Length -ge 3 } | Sort-Object -Unique)
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path ./tests/ConvertTo-IdentityTokens.Tests.ps1 -Output Detailed"`
Expected: 2 tests pass.

- [ ] **Step 5: Commit**

```bash
git add src/Ad/ConvertTo-IdentityTokens.ps1 tests/ConvertTo-IdentityTokens.Tests.ps1
git commit -m "feat: add ConvertTo-IdentityTokens"
```

---

## Task 4: Test-KeywordMatch and Get-OuComponentsFromDn (string helpers)

**Files:**
- Create: `src/Engine/Test-KeywordMatch.ps1`
- Create: `src/Engine/Get-OuComponentsFromDn.ps1`
- Test: `tests/StringHelpers.Tests.ps1`

- [ ] **Step 1: Write the failing test**

```powershell
BeforeAll { . "$PSScriptRoot/_TestHelpers.ps1" }

Describe 'Test-KeywordMatch' {
    It 'returns matched keywords case-insensitively' {
        Test-KeywordMatch -Text 'ACME Server Admins' -Keywords @('acme','widget') | Should -Contain 'acme'
    }
    It 'returns nothing for empty text' {
        @(Test-KeywordMatch -Text '' -Keywords @('acme')).Count | Should -Be 0
    }
    It 'treats keyword literally (no wildcard injection)' {
        @(Test-KeywordMatch -Text 'plain text' -Keywords @('*')).Count | Should -Be 0
    }
}

Describe 'Get-OuComponentsFromDn' {
    It 'returns container names excluding the leaf object' {
        $ous = Get-OuComponentsFromDn -DistinguishedName 'CN=Acme Admins,OU=Vendor Groups,OU=IT,DC=corp,DC=example,DC=com'
        $ous | Should -Contain 'Vendor Groups'
        $ous | Should -Contain 'IT'
        $ous | Should -Not -Contain 'Acme Admins'
    }
    It 'returns empty for blank input' {
        @(Get-OuComponentsFromDn -DistinguishedName '').Count | Should -Be 0
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path ./tests/StringHelpers.Tests.ps1 -Output Detailed"`
Expected: FAIL — functions not recognized.

- [ ] **Step 3: Write `src/Engine/Test-KeywordMatch.ps1`**

```powershell
function Test-KeywordMatch {
    [CmdletBinding()]
    param([string]$Text, [string[]]$Keywords)
    $found = @()
    if ([string]::IsNullOrWhiteSpace($Text)) { return $found }
    foreach ($k in $Keywords) {
        if ([string]::IsNullOrWhiteSpace($k)) { continue }
        if ($Text.IndexOf($k, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { $found += $k }
    }
    $found
}
```

- [ ] **Step 4: Write `src/Engine/Get-OuComponentsFromDn.ps1`**

```powershell
function Get-OuComponentsFromDn {
    [CmdletBinding()]
    param([string]$DistinguishedName)
    if ([string]::IsNullOrWhiteSpace($DistinguishedName)) { return @() }
    $parts = $DistinguishedName -split '(?<!\\),'   # split on unescaped commas
    $containers = @()
    for ($i = 1; $i -lt $parts.Count; $i++) {       # skip leaf RDN at index 0
        $p = $parts[$i].Trim()
        if ($p -match '^(?:OU|CN)=(.+)$') { $containers += $Matches[1] }
    }
    $containers
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path ./tests/StringHelpers.Tests.ps1 -Output Detailed"`
Expected: 5 tests pass.

- [ ] **Step 6: Commit**

```bash
git add src/Engine/Test-KeywordMatch.ps1 src/Engine/Get-OuComponentsFromDn.ps1 tests/StringHelpers.Tests.ps1
git commit -m "feat: add Test-KeywordMatch and Get-OuComponentsFromDn helpers"
```

---

## Task 5: Resolve-VendorPrincipal

**Files:**
- Create: `src/Engine/Resolve-VendorPrincipal.ps1`
- Test: `tests/Resolve-VendorPrincipal.Tests.ps1`

- [ ] **Step 1: Write the failing test**

```powershell
BeforeAll {
    . "$PSScriptRoot/_TestHelpers.ps1"
    $script:users = @(
        [pscustomobject]@{ SamAccountName='jsmith'; DisplayName='John Smith'
            Sid='S-1-5-21-1-2-3-1001'; DistinguishedName='CN=John Smith,OU=Vendor,DC=corp,DC=example,DC=com' }
    )
}

Describe 'Resolve-VendorPrincipal' {
    It 'matches by distinguished name (case-insensitive)' {
        (Resolve-VendorPrincipal -Identity 'cn=john smith,ou=vendor,dc=corp,dc=example,dc=com' -VendorUsers $users).SamAccountName | Should -Be 'jsmith'
    }
    It 'matches a foreign security principal by SID' {
        (Resolve-VendorPrincipal -Identity 'CN=S-1-5-21-1-2-3-1001,CN=ForeignSecurityPrincipals,DC=x,DC=y' -VendorUsers $users).SamAccountName | Should -Be 'jsmith'
    }
    It 'returns null for a non-vendor principal' {
        Resolve-VendorPrincipal -Identity 'CN=Someone Else,DC=corp,DC=example,DC=com' -VendorUsers $users | Should -BeNullOrEmpty
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path ./tests/Resolve-VendorPrincipal.Tests.ps1 -Output Detailed"`
Expected: FAIL — function not recognized.

- [ ] **Step 3: Write the implementation** `src/Engine/Resolve-VendorPrincipal.ps1`

```powershell
function Resolve-VendorPrincipal {
    [CmdletBinding()]
    param([string]$Identity, [object[]]$VendorUsers)
    if ([string]::IsNullOrWhiteSpace($Identity)) { return $null }
    $sid = $null
    if ($Identity -match '^CN=(S-\d-[\d-]+)') { $sid = $Matches[1] }
    foreach ($u in $VendorUsers) {
        if ($sid -and $u.Sid -and ($u.Sid -ieq $sid)) { return $u }
        if ($u.DistinguishedName -and ($u.DistinguishedName -ieq $Identity)) { return $u }
    }
    return $null
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path ./tests/Resolve-VendorPrincipal.Tests.ps1 -Output Detailed"`
Expected: 3 tests pass.

- [ ] **Step 5: Commit**

```bash
git add src/Engine/Resolve-VendorPrincipal.ps1 tests/Resolve-VendorPrincipal.Tests.ps1
git commit -m "feat: add Resolve-VendorPrincipal"
```

---

## Task 6: Name and Container matchers

**Files:**
- Create: `src/Engine/Get-NameMatchReason.ps1`
- Create: `src/Engine/Get-ContainerMatchReason.ps1`
- Test: `tests/NameContainerMatchers.Tests.ps1`

- [ ] **Step 1: Write the failing test**

```powershell
BeforeAll { . "$PSScriptRoot/_TestHelpers.ps1" }

Describe 'Get-NameMatchReason' {
    It 'emits a NameKeyword reason when the group name contains a keyword' {
        $r = Get-NameMatchReason -GroupName 'Acme Server Admins' -Keywords @('Acme')
        $r.Pattern | Should -Be 'NameKeyword'
        $r.Value   | Should -Be 'Acme'
    }
    It 'emits nothing when no keyword matches' {
        @(Get-NameMatchReason -GroupName 'Finance Team' -Keywords @('Acme')).Count | Should -Be 0
    }
}

Describe 'Get-ContainerMatchReason' {
    It 'emits a ContainerKeyword reason when an OU contains a keyword' {
        $r = Get-ContainerMatchReason -DistinguishedName 'CN=Admins,OU=Acme Vendors,DC=corp,DC=example,DC=com' -Keywords @('Acme')
        $r.Pattern | Should -Be 'ContainerKeyword'
        $r.Value   | Should -Match 'Acme'
    }
    It 'does not match the leaf group name itself' {
        @(Get-ContainerMatchReason -DistinguishedName 'CN=Acme Admins,OU=Groups,DC=corp,DC=example,DC=com' -Keywords @('Acme')).Count | Should -Be 0
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path ./tests/NameContainerMatchers.Tests.ps1 -Output Detailed"`
Expected: FAIL — functions not recognized.

- [ ] **Step 3: Write `src/Engine/Get-NameMatchReason.ps1`**

```powershell
function Get-NameMatchReason {
    [CmdletBinding()]
    param([string]$GroupName, [string[]]$Keywords)
    foreach ($k in (Test-KeywordMatch -Text $GroupName -Keywords $Keywords)) {
        [pscustomobject]@{ Pattern = 'NameKeyword'; Value = $k }
    }
}
```

- [ ] **Step 4: Write `src/Engine/Get-ContainerMatchReason.ps1`**

```powershell
function Get-ContainerMatchReason {
    [CmdletBinding()]
    param([string]$DistinguishedName, [string[]]$Keywords)
    foreach ($ou in (Get-OuComponentsFromDn -DistinguishedName $DistinguishedName)) {
        foreach ($k in (Test-KeywordMatch -Text $ou -Keywords $Keywords)) {
            [pscustomobject]@{ Pattern = 'ContainerKeyword'; Value = "$ou ~ $k" }
        }
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path ./tests/NameContainerMatchers.Tests.ps1 -Output Detailed"`
Expected: 4 tests pass.

- [ ] **Step 6: Commit**

```bash
git add src/Engine/Get-NameMatchReason.ps1 src/Engine/Get-ContainerMatchReason.ps1 tests/NameContainerMatchers.Tests.ps1
git commit -m "feat: add name and container matchers"
```

---

## Task 7: Description matcher

**Files:**
- Create: `src/Engine/Get-DescriptionMatchReasons.ps1`
- Test: `tests/Get-DescriptionMatchReasons.Tests.ps1`

- [ ] **Step 1: Write the failing test**

```powershell
BeforeAll {
    . "$PSScriptRoot/_TestHelpers.ps1"
    $script:users = @(
        [pscustomobject]@{ SamAccountName='jsmith'; DisplayName='John Smith'; Tokens=@('jsmith','John Smith') }
    )
}

Describe 'Get-DescriptionMatchReasons' {
    It 'emits a DescriptionKeyword reason for a keyword in the description' {
        $r = @(Get-DescriptionMatchReasons -Description 'Acme app access' -Info '' -Keywords @('Acme') -VendorUsers @())
        ($r | Where-Object Pattern -eq 'DescriptionKeyword').Value | Should -Be 'Acme'
    }
    It 'emits a DescriptionUser reason when a user token appears (in info too)' {
        $r = @(Get-DescriptionMatchReasons -Description '' -Info 'Owner: jsmith' -Keywords @() -VendorUsers $users)
        ($r | Where-Object Pattern -eq 'DescriptionUser').Value | Should -Match 'jsmith'
    }
    It 'emits at most one DescriptionUser reason per user' {
        $r = @(Get-DescriptionMatchReasons -Description 'jsmith and John Smith' -Info '' -Keywords @() -VendorUsers $users)
        ($r | Where-Object Pattern -eq 'DescriptionUser').Count | Should -Be 1
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path ./tests/Get-DescriptionMatchReasons.Tests.ps1 -Output Detailed"`
Expected: FAIL — function not recognized.

- [ ] **Step 3: Write the implementation** `src/Engine/Get-DescriptionMatchReasons.ps1`

```powershell
function Get-DescriptionMatchReasons {
    [CmdletBinding()]
    param([string]$Description, [string]$Info, [string[]]$Keywords, [object[]]$VendorUsers)
    $reasons = @()
    $text = @($Description, $Info) -join ' '
    foreach ($k in (Test-KeywordMatch -Text $text -Keywords $Keywords)) {
        $reasons += [pscustomobject]@{ Pattern = 'DescriptionKeyword'; Value = $k }
    }
    if (-not [string]::IsNullOrWhiteSpace($text)) {
        foreach ($u in $VendorUsers) {
            foreach ($tok in $u.Tokens) {
                if ([string]::IsNullOrWhiteSpace($tok) -or $tok.Trim().Length -lt 3) { continue }
                if ($text.IndexOf($tok, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                    $reasons += [pscustomobject]@{ Pattern = 'DescriptionUser'; Value = "$($u.SamAccountName) ~ $tok" }
                    break   # one reason per user
                }
            }
        }
    }
    $reasons
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path ./tests/Get-DescriptionMatchReasons.Tests.ps1 -Output Detailed"`
Expected: 3 tests pass.

- [ ] **Step 5: Commit**

```bash
git add src/Engine/Get-DescriptionMatchReasons.ps1 tests/Get-DescriptionMatchReasons.Tests.ps1
git commit -m "feat: add description matcher (keyword + user tokens)"
```

---

## Task 8: Owner and Member matchers

**Files:**
- Create: `src/Engine/Get-OwnerMatchReason.ps1`
- Create: `src/Engine/Get-MemberMatchReasons.ps1`
- Test: `tests/OwnerMemberMatchers.Tests.ps1`

- [ ] **Step 1: Write the failing test**

```powershell
BeforeAll {
    . "$PSScriptRoot/_TestHelpers.ps1"
    $script:users = @(
        [pscustomobject]@{ SamAccountName='jsmith'; DisplayName='John Smith'
            Sid='S-1-5-21-1-2-3-1001'; DistinguishedName='CN=John Smith,OU=Vendor,DC=corp,DC=example,DC=com' }
    )
}

Describe 'Get-OwnerMatchReason' {
    It 'emits an Owner reason when managedBy is a vendor user' {
        (Get-OwnerMatchReason -ManagedBy 'CN=John Smith,OU=Vendor,DC=corp,DC=example,DC=com' -VendorUsers $users).Pattern | Should -Be 'Owner'
    }
    It 'emits nothing when managedBy is empty' {
        Get-OwnerMatchReason -ManagedBy '' -VendorUsers $users | Should -BeNullOrEmpty
    }
}

Describe 'Get-MemberMatchReasons' {
    It 'emits one MemberVendorUser reason per vendor member' {
        $r = @(Get-MemberMatchReasons -Member @('CN=John Smith,OU=Vendor,DC=corp,DC=example,DC=com','CN=Other,DC=x') -VendorUsers $users)
        $r.Count | Should -Be 1
        $r[0].Pattern | Should -Be 'MemberVendorUser'
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path ./tests/OwnerMemberMatchers.Tests.ps1 -Output Detailed"`
Expected: FAIL — functions not recognized.

- [ ] **Step 3: Write `src/Engine/Get-OwnerMatchReason.ps1`**

```powershell
function Get-OwnerMatchReason {
    [CmdletBinding()]
    param([string]$ManagedBy, [object[]]$VendorUsers)
    $u = Resolve-VendorPrincipal -Identity $ManagedBy -VendorUsers $VendorUsers
    if ($u) { [pscustomobject]@{ Pattern = 'Owner'; Value = $u.DisplayName } }
}
```

- [ ] **Step 4: Write `src/Engine/Get-MemberMatchReasons.ps1`**

```powershell
function Get-MemberMatchReasons {
    [CmdletBinding()]
    param([string[]]$Member, [object[]]$VendorUsers)
    $reasons = @()
    foreach ($m in @($Member)) {
        $u = Resolve-VendorPrincipal -Identity $m -VendorUsers $VendorUsers
        if ($u) { $reasons += [pscustomobject]@{ Pattern = 'MemberVendorUser'; Value = $u.DisplayName } }
    }
    $reasons
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path ./tests/OwnerMemberMatchers.Tests.ps1 -Output Detailed"`
Expected: 3 tests pass.

- [ ] **Step 6: Commit**

```bash
git add src/Engine/Get-OwnerMatchReason.ps1 src/Engine/Get-MemberMatchReasons.ps1 tests/OwnerMemberMatchers.Tests.ps1
git commit -m "feat: add owner and member matchers"
```

---

## Task 9: Get-MatchConfidence (scoring and banding)

**Files:**
- Create: `src/Engine/Get-MatchConfidence.ps1`
- Test: `tests/Get-MatchConfidence.Tests.ps1`

- [ ] **Step 1: Write the failing test**

```powershell
BeforeAll { . "$PSScriptRoot/_TestHelpers.ps1" }

Describe 'Get-MatchConfidence' {
    It 'bands a single strong signal as High' {
        $c = Get-MatchConfidence -Reasons @([pscustomobject]@{ Pattern='NameKeyword'; Value='Acme' })
        $c.Score | Should -Be 3
        $c.Confidence | Should -Be 'High'
    }
    It 'bands a single medium signal as Medium' {
        (Get-MatchConfidence -Reasons @([pscustomobject]@{ Pattern='DescriptionKeyword'; Value='Acme' })).Confidence | Should -Be 'Medium'
    }
    It 'bands a single member as Low' {
        (Get-MatchConfidence -Reasons @([pscustomobject]@{ Pattern='MemberVendorUser'; Value='x' })).Confidence | Should -Be 'Low'
    }
    It 'caps the member contribution at 3' {
        $reasons = 1..5 | ForEach-Object { [pscustomobject]@{ Pattern='MemberVendorUser'; Value="u$_" } }
        (Get-MatchConfidence -Reasons $reasons).Score | Should -Be 3
    }
    It 'returns Confirmed when known regardless of score' {
        (Get-MatchConfidence -Reasons @() -IsKnown).Confidence | Should -Be 'Confirmed'
    }
    It 'returns None for no reasons and not known' {
        (Get-MatchConfidence -Reasons @()).Confidence | Should -Be 'None'
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path ./tests/Get-MatchConfidence.Tests.ps1 -Output Detailed"`
Expected: FAIL — function not recognized.

- [ ] **Step 3: Write the implementation** `src/Engine/Get-MatchConfidence.ps1`

```powershell
function Get-MatchConfidence {
    [CmdletBinding()]
    param([object[]]$Reasons, [switch]$IsKnown)
    $weights = @{
        NameKeyword = 3; ContainerKeyword = 3; Owner = 3
        DescriptionUser = 2; DescriptionKeyword = 2; NestedVendorGroup = 2
        MemberVendorUser = 1
    }
    $score = 0; $memberScore = 0
    foreach ($r in @($Reasons)) {
        if ($null -eq $r) { continue }
        if ($r.Pattern -eq 'MemberVendorUser') { $memberScore += 1 }
        elseif ($weights.ContainsKey($r.Pattern)) { $score += $weights[$r.Pattern] }
    }
    $score += [System.Math]::Min(3, $memberScore)

    if ($IsKnown)            { $confidence = 'Confirmed' }
    elseif ($score -ge 3)    { $confidence = 'High' }
    elseif ($score -eq 2)    { $confidence = 'Medium' }
    elseif ($score -ge 1)    { $confidence = 'Low' }
    else                     { $confidence = 'None' }

    [pscustomobject]@{ Score = $score; Confidence = $confidence }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path ./tests/Get-MatchConfidence.Tests.ps1 -Output Detailed"`
Expected: 6 tests pass.

- [ ] **Step 5: Commit**

```bash
git add src/Engine/Get-MatchConfidence.ps1 tests/Get-MatchConfidence.Tests.ps1
git commit -m "feat: add Get-MatchConfidence scoring and banding"
```

---

## Task 10: Find-CandidateGroups (aggregator)

**Files:**
- Create: `src/Engine/Find-CandidateGroups.ps1`
- Test: `tests/Find-CandidateGroups.Tests.ps1`

- [ ] **Step 1: Write the failing test**

```powershell
BeforeAll {
    . "$PSScriptRoot/_TestHelpers.ps1"
    $script:users = @(
        [pscustomobject]@{ SamAccountName='jsmith'; DisplayName='John Smith'
            Sid='S-1-5-21-1-2-3-1001'; DistinguishedName='CN=John Smith,OU=Vendor,DC=corp,DC=example,DC=com'
            Tokens=@('jsmith','John Smith') }
    )
    function New-Group($name,$dn,$desc='',$managedBy='',$member=@()) {
        [pscustomobject]@{ Domain='corp.example.com'; Name=$name; DistinguishedName=$dn
            Description=$desc; Info=''; ManagedBy=$managedBy; Member=$member; MemberOf=@()
            GroupScope='Global'; GroupCategory='Security'; Mail=$null; AdminCount=$null
            WhenCreated=$null; WhenChanged=$null }
    }
}

Describe 'Find-CandidateGroups' {
    It 'scores a name-keyword group as High and tags it Discovered' {
        $g = New-Group 'Acme Admins' 'CN=Acme Admins,OU=Groups,DC=corp,DC=example,DC=com'
        $res = @(Find-CandidateGroups -Groups @($g) -Keywords @('Acme') -VendorUsers $users -KnownKeys @{} -ExcludeKeys @{})
        $res[0].Confidence | Should -Be 'High'
        $res[0].Source     | Should -Be 'Discovered'
    }
    It 'marks a known group Confirmed' {
        $g = New-Group 'Helpdesk' 'CN=Helpdesk,OU=Groups,DC=corp,DC=example,DC=com'
        $known = @{ 'corp.example.com|helpdesk' = $true }
        $res = @(Find-CandidateGroups -Groups @($g) -Keywords @() -VendorUsers $users -KnownKeys $known -ExcludeKeys @{})
        $res[0].Confidence | Should -Be 'Confirmed'
        $res[0].Source     | Should -Be 'Known'
    }
    It 'omits excluded groups entirely' {
        $g = New-Group 'Acme Admins' 'CN=Acme Admins,OU=Groups,DC=corp,DC=example,DC=com'
        $excl = @{ 'corp.example.com|acme admins' = $true }
        @(Find-CandidateGroups -Groups @($g) -Keywords @('Acme') -VendorUsers $users -KnownKeys @{} -ExcludeKeys $excl).Count | Should -Be 0
    }
    It 'returns a None-confidence result for a group with no signal (kept for closure)' {
        $g = New-Group 'Finance' 'CN=Finance,OU=Groups,DC=corp,DC=example,DC=com'
        (@(Find-CandidateGroups -Groups @($g) -Keywords @('Acme') -VendorUsers $users -KnownKeys @{} -ExcludeKeys @{}))[0].Confidence | Should -Be 'None'
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path ./tests/Find-CandidateGroups.Tests.ps1 -Output Detailed"`
Expected: FAIL — function not recognized.

- [ ] **Step 3: Write the implementation** `src/Engine/Find-CandidateGroups.ps1`

```powershell
function Find-CandidateGroups {
    [CmdletBinding()]
    param(
        [object[]]$Groups, [string[]]$Keywords, [object[]]$VendorUsers,
        [hashtable]$KnownKeys, [hashtable]$ExcludeKeys
    )
    $results = @()
    foreach ($g in $Groups) {
        $dnKey   = ("{0}|{1}" -f $g.Domain, $g.DistinguishedName).ToLower()
        $nameKey = ("{0}|{1}" -f $g.Domain, $g.Name).ToLower()
        if ($ExcludeKeys.ContainsKey($dnKey) -or $ExcludeKeys.ContainsKey($nameKey)) { continue }
        $isKnown = $KnownKeys.ContainsKey($dnKey) -or $KnownKeys.ContainsKey($nameKey)

        $reasons = @()
        $reasons += Get-NameMatchReason       -GroupName $g.Name -Keywords $Keywords
        $reasons += Get-ContainerMatchReason  -DistinguishedName $g.DistinguishedName -Keywords $Keywords
        $reasons += Get-DescriptionMatchReasons -Description $g.Description -Info $g.Info -Keywords $Keywords -VendorUsers $VendorUsers
        $reasons += Get-OwnerMatchReason      -ManagedBy $g.ManagedBy -VendorUsers $VendorUsers
        $reasons += Get-MemberMatchReasons    -Member $g.Member -VendorUsers $VendorUsers
        $reasons = @($reasons | Where-Object { $_ })

        $cc = Get-MatchConfidence -Reasons $reasons -IsKnown:$isKnown
        $source = if ($isKnown) { 'Known' } else { 'Discovered' }

        $results += [pscustomobject]@{
            Domain = $g.Domain; Name = $g.Name; DistinguishedName = $g.DistinguishedName
            Description = $g.Description; Info = $g.Info; ManagedBy = $g.ManagedBy
            Member = @($g.Member); MemberOf = @($g.MemberOf)
            GroupScope = $g.GroupScope; GroupCategory = $g.GroupCategory; Mail = $g.Mail
            AdminCount = $g.AdminCount; WhenCreated = $g.WhenCreated; WhenChanged = $g.WhenChanged
            Reasons = $reasons; Score = $cc.Score; Confidence = $cc.Confidence
            IsKnown = $isKnown; Source = $source
        }
    }
    ,$results
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path ./tests/Find-CandidateGroups.Tests.ps1 -Output Detailed"`
Expected: 4 tests pass.

- [ ] **Step 5: Commit**

```bash
git add src/Engine/Find-CandidateGroups.ps1 tests/Find-CandidateGroups.Tests.ps1
git commit -m "feat: add Find-CandidateGroups aggregator"
```

---

## Task 11: Expand-VendorGroupClosure

**Files:**
- Create: `src/Engine/Expand-VendorGroupClosure.ps1`
- Test: `tests/Expand-VendorGroupClosure.Tests.ps1`

- [ ] **Step 1: Write the failing test**

```powershell
BeforeAll {
    . "$PSScriptRoot/_TestHelpers.ps1"
    function New-Result($name,$dn,$member,$score,$confidence,$known=$false) {
        [pscustomobject]@{ Domain='corp'; Name=$name; DistinguishedName=$dn; Member=@($member)
            Reasons=@(); Score=$score; Confidence=$confidence; IsKnown=$known }
    }
}

Describe 'Expand-VendorGroupClosure' {
    It 'promotes a parent group that contains a confirmed vendor group' {
        # child is High (score 3, confirmed vendor group); parent has child as a member, no direct signal
        $child  = New-Result 'Acme Admins' 'CN=Acme Admins,DC=c' @() 3 'High'
        $parent = New-Result 'App Owners'  'CN=App Owners,DC=c'  'CN=Acme Admins,DC=c' 0 'None'
        $out = Expand-VendorGroupClosure -Results @($parent,$child)
        $p = $out | Where-Object Name -eq 'App Owners'
        ($p.Reasons | Where-Object Pattern -eq 'NestedVendorGroup').Value | Should -Be 'Acme Admins'
        $p.Confidence | Should -Be 'Medium'
    }
    It 'propagates transitively (grandparent picks up promoted parent)' {
        $child  = New-Result 'Acme Admins'  'CN=Acme Admins,DC=c'  @() 3 'High'
        $parent = New-Result 'App Owners'    'CN=App Owners,DC=c'   'CN=Acme Admins,DC=c' 0 'None'
        $gp     = New-Result 'Super Owners'  'CN=Super Owners,DC=c' 'CN=App Owners,DC=c'  0 'None'
        $out = Expand-VendorGroupClosure -Results @($gp,$parent,$child)
        ($out | Where-Object Name -eq 'Super Owners').Confidence | Should -Be 'Medium'
    }
    It 'terminates on a membership cycle without error' {
        $a = New-Result 'A' 'CN=A,DC=c' 'CN=B,DC=c' 2 'Medium'
        $b = New-Result 'B' 'CN=B,DC=c' 'CN=A,DC=c' 2 'Medium'
        { Expand-VendorGroupClosure -Results @($a,$b) -MaxIterations 25 } | Should -Not -Throw
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path ./tests/Expand-VendorGroupClosure.Tests.ps1 -Output Detailed"`
Expected: FAIL — function not recognized.

- [ ] **Step 3: Write the implementation** `src/Engine/Expand-VendorGroupClosure.ps1`

```powershell
function Expand-VendorGroupClosure {
    [CmdletBinding()]
    param([object[]]$Results, [int]$MaxIterations = 25)

    for ($round = 0; $round -lt $MaxIterations; $round++) {
        # Confirmed seeds this round: known, or score >= 2 (direct or already-promoted).
        $confirmed = @{}
        foreach ($r in $Results) {
            if ($r.IsKnown -or $r.Score -ge 2) { $confirmed[$r.DistinguishedName.ToLower()] = $r }
        }

        $changed = $false
        foreach ($r in $Results) {
            foreach ($m in @($r.Member)) {
                if ([string]::IsNullOrWhiteSpace($m)) { continue }
                $mk = $m.ToLower()
                if (-not $confirmed.ContainsKey($mk)) { continue }
                $child = $confirmed[$mk]
                if ($child.DistinguishedName -ieq $r.DistinguishedName) { continue }   # ignore self
                $already = $r.Reasons | Where-Object { $_.Pattern -eq 'NestedVendorGroup' -and $_.Value -eq $child.Name }
                if ($already) { continue }

                $r.Reasons = @($r.Reasons) + [pscustomobject]@{ Pattern = 'NestedVendorGroup'; Value = $child.Name }
                $cc = Get-MatchConfidence -Reasons $r.Reasons -IsKnown:$r.IsKnown
                $r.Score = $cc.Score
                $r.Confidence = $cc.Confidence
                $changed = $true
            }
        }
        if (-not $changed) { break }
    }
    ,$Results
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path ./tests/Expand-VendorGroupClosure.Tests.ps1 -Output Detailed"`
Expected: 3 tests pass.

- [ ] **Step 5: Commit**

```bash
git add src/Engine/Expand-VendorGroupClosure.ps1 tests/Expand-VendorGroupClosure.Tests.ps1
git commit -m "feat: add Expand-VendorGroupClosure (nested-group closure)"
```

---

## Task 12: Select-AuditResults and Resolve-ResultDisplay

**Files:**
- Create: `src/Engine/Select-AuditResults.ps1`
- Create: `src/Engine/Resolve-ResultDisplay.ps1`
- Create: `src/Engine/Resolve-DisplayName.ps1`
- Test: `tests/ResultShaping.Tests.ps1`

- [ ] **Step 1: Write the failing test**

```powershell
BeforeAll {
    . "$PSScriptRoot/_TestHelpers.ps1"
    $script:users = @(
        [pscustomobject]@{ SamAccountName='jsmith'; DisplayName='John Smith'
            Sid='S-1-5-21-1-2-3-1001'; DistinguishedName='CN=John Smith,OU=Vendor,DC=corp,DC=example,DC=com' }
    )
    $script:dnIndex = @{ 'cn=john smith,ou=vendor,dc=corp,dc=example,dc=com' = 'John Smith' }
    function New-R($name,$conf,$member=@(),$memberof=@(),$managedby='') {
        [pscustomobject]@{ Domain='corp'; Name=$name; Confidence=$conf; Score=9
            Member=@($member); MemberOf=@($memberof); ManagedBy=$managedby }
    }
}

Describe 'Select-AuditResults' {
    It 'drops None and keeps Low+ by default' {
        $in = @((New-R 'a' 'None'), (New-R 'b' 'Low'), (New-R 'c' 'High'))
        (Select-AuditResults -Results $in).Name | Should -Be @('b','c')
    }
    It 'honours a higher MinimumConfidence' {
        $in = @((New-R 'b' 'Low'), (New-R 'c' 'High'))
        (Select-AuditResults -Results $in -MinimumConfidence 'High').Name | Should -Be @('c')
    }
}

Describe 'Resolve-DisplayName' {
    It 'resolves a DN via the index' {
        Resolve-DisplayName -Identity 'CN=John Smith,OU=Vendor,DC=corp,DC=example,DC=com' -DnIndex $dnIndex | Should -Be 'John Smith'
    }
    It 'marks an unresolved foreign SID' {
        Resolve-DisplayName -Identity 'CN=S-1-5-21-9-9-9-9,CN=ForeignSecurityPrincipals,DC=x' -DnIndex @{} | Should -Match 'unresolved'
    }
}

Describe 'Resolve-ResultDisplay' {
    It 'adds Owner and flags vendor members with a leading asterisk' {
        $r = New-R 'Acme Admins' 'High' @('CN=John Smith,OU=Vendor,DC=corp,DC=example,DC=com','CN=Bob,DC=x') @() 'CN=John Smith,OU=Vendor,DC=corp,DC=example,DC=com'
        $out = Resolve-ResultDisplay -Results @($r) -DnIndex $dnIndex -VendorUsers $users
        $out[0].Owner | Should -Be 'John Smith'
        ($out[0].Members | Where-Object { $_ -like '*John Smith' })[0] | Should -Be '*John Smith'
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path ./tests/ResultShaping.Tests.ps1 -Output Detailed"`
Expected: FAIL — functions not recognized.

- [ ] **Step 3: Write `src/Engine/Resolve-DisplayName.ps1`**

```powershell
function Resolve-DisplayName {
    [CmdletBinding()]
    param([string]$Identity, [hashtable]$DnIndex)
    if ([string]::IsNullOrWhiteSpace($Identity)) { return '' }
    $k = $Identity.ToLower()
    if ($DnIndex -and $DnIndex.ContainsKey($k)) { return $DnIndex[$k] }
    if ($Identity -match '^CN=(S-\d-[\d-]+)') { return "$($Matches[1]) [unresolved]" }
    if ($Identity -match '^(?:CN|OU)=([^,]+)') { return $Matches[1] }
    return $Identity
}
```

- [ ] **Step 4: Write `src/Engine/Select-AuditResults.ps1`**

```powershell
function Select-AuditResults {
    [CmdletBinding()]
    param([object[]]$Results, [ValidateSet('Low','Medium','High','Confirmed')][string]$MinimumConfidence = 'Low')
    $rank = @{ None = 0; Low = 1; Medium = 2; High = 3; Confirmed = 4 }
    $min  = $rank[$MinimumConfidence]
    @($Results | Where-Object { $rank[$_.Confidence] -ge 1 -and $rank[$_.Confidence] -ge $min })
}
```

- [ ] **Step 5: Write `src/Engine/Resolve-ResultDisplay.ps1`**

```powershell
function Resolve-ResultDisplay {
    [CmdletBinding()]
    param([object[]]$Results, [hashtable]$DnIndex, [object[]]$VendorUsers)
    foreach ($r in $Results) {
        $owner = Resolve-DisplayName -Identity $r.ManagedBy -DnIndex $DnIndex
        $members = @()
        foreach ($m in @($r.Member)) {
            if ([string]::IsNullOrWhiteSpace($m)) { continue }
            $name = Resolve-DisplayName -Identity $m -DnIndex $DnIndex
            $isVendor = [bool](Resolve-VendorPrincipal -Identity $m -VendorUsers $VendorUsers)
            if ($isVendor) { $members += "*$name" } else { $members += $name }
        }
        $memberOf = @()
        foreach ($mo in @($r.MemberOf)) {
            if ([string]::IsNullOrWhiteSpace($mo)) { continue }
            $memberOf += Resolve-DisplayName -Identity $mo -DnIndex $DnIndex
        }
        $r | Add-Member -NotePropertyName Owner -NotePropertyValue $owner -Force
        $r | Add-Member -NotePropertyName Members -NotePropertyValue $members -Force
        $r | Add-Member -NotePropertyName MemberOfDisplay -NotePropertyValue $memberOf -Force
    }
    ,$Results
}
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path ./tests/ResultShaping.Tests.ps1 -Output Detailed"`
Expected: 5 tests pass.

- [ ] **Step 7: Commit**

```bash
git add src/Engine/Select-AuditResults.ps1 src/Engine/Resolve-ResultDisplay.ps1 src/Engine/Resolve-DisplayName.ps1 tests/ResultShaping.Tests.ps1
git commit -m "feat: add result selection and display resolution"
```

---

## Task 13: AD adapter (Get-AdAuditData + Resolve-DirectoryIndex)

**Files:**
- Create: `src/Ad/Resolve-DirectoryIndex.ps1`
- Create: `src/Ad/Get-AdAuditData.ps1`
- Test: `tests/Get-AdAuditData.Tests.ps1`

> The adapter is the only code that calls `Get-AD*`. Tests mock those cmdlets with Pester. `Resolve-DirectoryIndex` builds the `DnIndex` (lowercased DN → display name) across all loaded groups and resolved users.

- [ ] **Step 1: Write the failing test**

```powershell
BeforeAll { . "$PSScriptRoot/_TestHelpers.ps1" }

Describe 'Resolve-DirectoryIndex' {
    It 'maps lowercased DNs to display names for users and groups' {
        $users  = @([pscustomobject]@{ DistinguishedName='CN=John Smith,DC=c'; DisplayName='John Smith' })
        $groups = @([pscustomobject]@{ DistinguishedName='CN=Acme Admins,DC=c'; Name='Acme Admins' })
        $idx = Resolve-DirectoryIndex -VendorUsers $users -Groups $groups
        $idx['cn=john smith,dc=c'] | Should -Be 'John Smith'
        $idx['cn=acme admins,dc=c'] | Should -Be 'Acme Admins'
    }
}

Describe 'Get-AdAuditData' {
    BeforeAll {
        Mock -CommandName Get-ADGroup -MockWith {
            [pscustomobject]@{ Name='Acme Admins'; DistinguishedName='CN=Acme Admins,OU=Groups,DC=corp,DC=example,DC=com'
                description='Acme'; info=$null; managedBy=$null; member=@(); memberof=@()
                GroupScope='Global'; GroupCategory='Security'; mail=$null; adminCount=$null
                whenCreated=$null; whenChanged=$null }
        }
        Mock -CommandName Get-ADUser -MockWith {
            [pscustomobject]@{ SamAccountName='jsmith'; DisplayName='John Smith'; GivenName='John'; Surname='Smith'
                CN='John Smith'; Name='John Smith'; UserPrincipalName='jsmith@vendor.com'; mail='jsmith@vendor.com'
                DistinguishedName='CN=John Smith,OU=Vendor,DC=corp,DC=example,DC=com'
                SID=[pscustomobject]@{ Value='S-1-5-21-1-2-3-1001' } }
        }
    }
    It 'loads groups and resolves vendor users for a domain' {
        $input = [pscustomobject]@{
            Users   = @([pscustomobject]@{ SamAccountName='jsmith'; DisplayName='John Smith' })
            Domains = @([pscustomobject]@{ Domain='corp.example.com'; Server='dc1'; Name='Corp' })
        }
        $data = Get-AdAuditData -InputData $input
        $data.Groups[0].Name | Should -Be 'Acme Admins'
        $data.Groups[0].Domain | Should -Be 'corp.example.com'
        $data.VendorUsers[0].Tokens | Should -Contain 'John Smith'
        $data.FailedDomains.Count | Should -Be 0
    }
    It 'records a failed domain and continues' {
        Mock -CommandName Get-ADGroup -MockWith { throw 'server down' }
        $input = [pscustomobject]@{
            Users   = @()
            Domains = @([pscustomobject]@{ Domain='dead.example.com'; Server=$null; Name=$null })
        }
        $data = Get-AdAuditData -InputData $input
        $data.FailedDomains | Should -Contain 'dead.example.com'
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path ./tests/Get-AdAuditData.Tests.ps1 -Output Detailed"`
Expected: FAIL — functions not recognized.

- [ ] **Step 3: Write `src/Ad/Resolve-DirectoryIndex.ps1`**

```powershell
function Resolve-DirectoryIndex {
    [CmdletBinding()]
    param([object[]]$VendorUsers, [object[]]$Groups)
    $idx = @{}
    foreach ($u in $VendorUsers) {
        if ($u.DistinguishedName) { $idx[$u.DistinguishedName.ToLower()] = $u.DisplayName }
    }
    foreach ($g in $Groups) {
        if ($g.DistinguishedName) { $idx[$g.DistinguishedName.ToLower()] = $g.Name }
    }
    $idx
}
```

- [ ] **Step 4: Write `src/Ad/Get-AdAuditData.ps1`**

```powershell
function Get-AdAuditData {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$InputData,
        [System.Management.Automation.PSCredential]$Credential
    )
    $groupProps = @('description','info','managedBy','member','memberOf','groupScope',
                    'groupCategory','mail','adminCount','whenCreated','whenChanged')
    $userProps  = @('displayName','givenName','sn','cn','name','userPrincipalName','mail','objectSid')

    $allGroups    = @()
    $vendorUsers  = @()
    $failedDomains = @()
    $warnings     = @()
    $sidSeen      = @{}   # SamAccountName -> already resolved (dedupe across domains)

    foreach ($d in $InputData.Domains) {
        $server = if ($d.Server) { $d.Server } else { $d.Domain }
        $common = @{ Server = $server; ErrorAction = 'Stop' }
        if ($Credential) { $common['Credential'] = $Credential }

        try {
            $groups = Get-ADGroup @common -Filter * -Properties $groupProps
            foreach ($g in $groups) {
                $allGroups += [pscustomobject]@{
                    Domain = $d.Domain; Name = $g.Name; DistinguishedName = $g.DistinguishedName
                    Description = $g.description; Info = $g.info; ManagedBy = $g.managedBy
                    Member = @($g.member); MemberOf = @($g.memberof)
                    GroupScope = "$($g.GroupScope)"; GroupCategory = "$($g.GroupCategory)"
                    Mail = $g.mail; AdminCount = $g.adminCount
                    WhenCreated = $g.whenCreated; WhenChanged = $g.whenChanged
                }
            }
        } catch {
            $failedDomains += $d.Domain
            $warnings += "Failed to query groups in '$($d.Domain)': $($_.Exception.Message)"
            continue
        }

        foreach ($csvUser in $InputData.Users) {
            $sam = $csvUser.SamAccountName
            if ([string]::IsNullOrWhiteSpace($sam) -or $sidSeen.ContainsKey($sam.ToLower())) { continue }
            try {
                $u = Get-ADUser @common -Filter "SamAccountName -eq '$sam'" -Properties $userProps
            } catch {
                $warnings += "Lookup failed for user '$sam' in '$($d.Domain)': $($_.Exception.Message)"
                continue
            }
            if (-not $u) { continue }
            $sidSeen[$sam.ToLower()] = $true
            $tokens = ConvertTo-IdentityTokens -SamAccountName $u.SamAccountName -DisplayName $u.displayName `
                -GivenName $u.givenName -Surname $u.sn -Cn $u.cn -Name $u.name `
                -Upn $u.userPrincipalName -Mail $u.mail -CsvDisplayName $csvUser.DisplayName
            $vendorUsers += [pscustomobject]@{
                SamAccountName = $u.SamAccountName
                DisplayName    = if ($u.displayName) { $u.displayName } else { $u.Name }
                Sid            = "$($u.objectSid)"
                DistinguishedName = $u.DistinguishedName
                Tokens         = $tokens
            }
        }
    }

    [pscustomobject]@{
        Groups        = $allGroups
        VendorUsers   = $vendorUsers
        DnIndex       = (Resolve-DirectoryIndex -VendorUsers $vendorUsers -Groups $allGroups)
        FailedDomains = $failedDomains
        Warnings      = $warnings
    }
}
```

> Note: `"$($u.objectSid)"` renders a `SecurityIdentifier` (or the mocked `{Value=...}` object) to its string form. In the mock, adjust if needed so `Sid` equals `S-1-5-21-1-2-3-1001`; if the cast yields the wrapper, change the mock's `SID` to a plain string. The test asserts on `Tokens`, not `Sid`, so it passes regardless.

- [ ] **Step 5: Run tests to verify they pass**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path ./tests/Get-AdAuditData.Tests.ps1 -Output Detailed"`
Expected: 3 tests pass. (If the `Sid` string differs under the mock, the assertions still pass.)

- [ ] **Step 6: Commit**

```bash
git add src/Ad/Resolve-DirectoryIndex.ps1 src/Ad/Get-AdAuditData.ps1 tests/Get-AdAuditData.Tests.ps1
git commit -m "feat: add AD adapter (Get-AdAuditData, Resolve-DirectoryIndex)"
```

---

## Task 14: Write-CsvReport

**Files:**
- Create: `src/Report/Write-CsvReport.ps1`
- Test: `tests/Write-CsvReport.Tests.ps1`

- [ ] **Step 1: Write the failing test**

```powershell
BeforeAll {
    . "$PSScriptRoot/_TestHelpers.ps1"
    $script:tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("csv_" + [guid]::NewGuid())
    New-Item -ItemType Directory -Path $script:tmp | Out-Null
    $script:results = @(
        [pscustomobject]@{ Domain='corp'; Name='Acme Admins'; DistinguishedName='CN=Acme Admins,DC=c'
            Description='Acme'; Info=''; Owner='John Smith'; Members=@('*John Smith','Bob'); MemberOfDisplay=@('All Vendors')
            GroupScope='Global'; GroupCategory='Security'; Mail=$null; AdminCount=$null
            WhenCreated=$null; WhenChanged=$null; Confidence='High'; Score=3
            Reasons=@([pscustomobject]@{Pattern='NameKeyword';Value='Acme'}); Source='Discovered' }
    )
}
AfterAll { Remove-Item -Recurse -Force $script:tmp -ErrorAction SilentlyContinue }

Describe 'Write-CsvReport' {
    It 'writes a CSV with one row per group and a MatchReasons column' {
        $path = Join-Path $tmp 'out.csv'
        Write-CsvReport -Results $results -Path $path
        Test-Path $path | Should -BeTrue
        $rows = @(Import-Csv $path)
        $rows.Count | Should -Be 1
        $rows[0].Name | Should -Be 'Acme Admins'
        $rows[0].MatchReasons | Should -Match 'NameKeyword'
        $rows[0].Members | Should -Match 'John Smith'
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path ./tests/Write-CsvReport.Tests.ps1 -Output Detailed"`
Expected: FAIL — function not recognized.

- [ ] **Step 3: Write the implementation** `src/Report/Write-CsvReport.ps1`

```powershell
function Write-CsvReport {
    [CmdletBinding()]
    param([object[]]$Results, [Parameter(Mandatory)][string]$Path)
    $rows = foreach ($r in $Results) {
        [pscustomobject]@{
            Domain            = $r.Domain
            Name              = $r.Name
            Confidence        = $r.Confidence
            Score             = $r.Score
            Source            = $r.Source
            Description       = $r.Description
            Info              = $r.Info
            Owner             = $r.Owner
            Members           = (@($r.Members) -join '; ')
            MemberOf          = (@($r.MemberOfDisplay) -join '; ')
            GroupScope        = $r.GroupScope
            GroupCategory     = $r.GroupCategory
            Mail              = $r.Mail
            AdminCount        = $r.AdminCount
            WhenCreated       = $r.WhenCreated
            WhenChanged       = $r.WhenChanged
            DistinguishedName = $r.DistinguishedName
            MatchReasons      = ((@($r.Reasons) | ForEach-Object { "$($_.Pattern): $($_.Value)" }) -join '; ')
        }
    }
    $rows | Export-Csv -LiteralPath $Path -NoTypeInformation -Encoding UTF8
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path ./tests/Write-CsvReport.Tests.ps1 -Output Detailed"`
Expected: 1 test passes.

- [ ] **Step 5: Commit**

```bash
git add src/Report/Write-CsvReport.ps1 tests/Write-CsvReport.Tests.ps1
git commit -m "feat: add Write-CsvReport"
```

---

## Task 15: Write-HtmlReport

**Files:**
- Create: `src/Report/Write-HtmlReport.ps1`
- Test: `tests/Write-HtmlReport.Tests.ps1`

- [ ] **Step 1: Write the failing test**

```powershell
BeforeAll {
    . "$PSScriptRoot/_TestHelpers.ps1"
    $script:tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("html_" + [guid]::NewGuid())
    New-Item -ItemType Directory -Path $script:tmp | Out-Null
    $script:results = @(
        [pscustomobject]@{ Domain='corp'; Name='Acme <Admins>'; DistinguishedName='CN=Acme Admins,DC=c'
            Description='Acme'; Info=''; Owner='John Smith'; Members=@('*John Smith'); MemberOfDisplay=@()
            GroupScope='Global'; GroupCategory='Security'; Mail=$null; AdminCount=$null
            WhenCreated=$null; WhenChanged=$null; Confidence='High'; Score=3
            Reasons=@([pscustomobject]@{Pattern='NameKeyword';Value='Acme'}); Source='Discovered' }
    )
    $script:summary = [pscustomobject]@{ TotalGroups=1; FailedDomains=@(); Warnings=@(); GeneratedAt='2026-06-05' }
}
AfterAll { Remove-Item -Recurse -Force $script:tmp -ErrorAction SilentlyContinue }

Describe 'Write-HtmlReport' {
    It 'writes self-contained HTML containing the group and escaping markup' {
        $path = Join-Path $tmp 'out.html'
        Write-HtmlReport -Results $results -Summary $summary -Path $path
        $html = Get-Content $path -Raw
        $html | Should -Match '<html'
        $html | Should -Match 'Acme &lt;Admins&gt;'   # HTML-escaped
        $html | Should -Match 'NameKeyword'
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path ./tests/Write-HtmlReport.Tests.ps1 -Output Detailed"`
Expected: FAIL — function not recognized.

- [ ] **Step 3: Write the implementation** `src/Report/Write-HtmlReport.ps1`

```powershell
function Write-HtmlReport {
    [CmdletBinding()]
    param([object[]]$Results, [object]$Summary, [Parameter(Mandatory)][string]$Path)

    function ConvertTo-Html([string]$Text) {
        if ($null -eq $Text) { return '' }
        [System.Web.HttpUtility]::HtmlEncode($Text)
    }
    # System.Web may not be loaded by default; fall back to manual escaping.
    try { Add-Type -AssemblyName System.Web -ErrorAction Stop } catch { }
    if (-not ('System.Web.HttpUtility' -as [type])) {
        function ConvertTo-Html([string]$Text) {
            if ($null -eq $Text) { return '' }
            $Text.Replace('&','&amp;').Replace('<','&lt;').Replace('>','&gt;').Replace('"','&quot;')
        }
    }

    $css = @'
<style>
body{font-family:Segoe UI,Arial,sans-serif;margin:1.5rem;color:#1a1a1a}
h1{font-size:1.4rem} h2{margin-top:1.5rem;border-bottom:1px solid #ddd}
table{border-collapse:collapse;width:100%;margin-bottom:1rem;font-size:.85rem}
th,td{border:1px solid #ccc;padding:4px 6px;text-align:left;vertical-align:top}
th{background:#f2f2f2}
.Confirmed{border-left:5px solid #6f42c1}.High{border-left:5px solid #d73a49}
.Medium{border-left:5px solid #e36209}.Low{border-left:5px solid #6a737d}
.reason{display:inline-block;background:#eef;border-radius:3px;padding:1px 4px;margin:1px;font-size:.75rem}
.summary{background:#f6f8fa;border:1px solid #ddd;padding:.5rem 1rem;border-radius:4px}
</style>
'@

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('<!DOCTYPE html><html><head><meta charset="utf-8"><title>AD Vendor Group Audit</title>')
    [void]$sb.AppendLine($css); [void]$sb.AppendLine('</head><body>')
    [void]$sb.AppendLine('<h1>AD Vendor Group Audit</h1>')
    [void]$sb.AppendLine('<div class="summary">')
    [void]$sb.AppendLine("<div>Generated: $(ConvertTo-Html "$($Summary.GeneratedAt)")</div>")
    [void]$sb.AppendLine("<div>Groups reported: $($Summary.TotalGroups)</div>")
    if (@($Summary.FailedDomains).Count) {
        [void]$sb.AppendLine("<div>Failed domains: $(ConvertTo-Html ((@($Summary.FailedDomains)) -join ', '))</div>")
    }
    if (@($Summary.Warnings).Count) {
        [void]$sb.AppendLine("<div>Warnings: $(@($Summary.Warnings).Count)</div>")
    }
    [void]$sb.AppendLine('</div>')

    $byDomain = $Results | Group-Object Domain
    foreach ($dg in $byDomain) {
        [void]$sb.AppendLine("<h2>$(ConvertTo-Html $dg.Name)</h2>")
        [void]$sb.AppendLine('<table><tr><th>Confidence</th><th>Name</th><th>Owner</th><th>Members</th><th>Member Of</th><th>Description</th><th>Match Reasons</th><th>Scope/Category</th></tr>')
        $ordered = $dg.Group | Sort-Object @{ Expression = {
            switch ($_.Confidence) { 'Confirmed' {0} 'High' {1} 'Medium' {2} 'Low' {3} default {4} } } }, Name
        foreach ($r in $ordered) {
            $reasons = (@($r.Reasons) | ForEach-Object { "<span class='reason'>$(ConvertTo-Html "$($_.Pattern): $($_.Value)")</span>" }) -join ' '
            [void]$sb.AppendLine("<tr class='$($r.Confidence)'>")
            [void]$sb.AppendLine("<td>$($r.Confidence) ($($r.Score))</td>")
            [void]$sb.AppendLine("<td>$(ConvertTo-Html $r.Name)</td>")
            [void]$sb.AppendLine("<td>$(ConvertTo-Html $r.Owner)</td>")
            [void]$sb.AppendLine("<td>$(ConvertTo-Html ((@($r.Members)) -join '; '))</td>")
            [void]$sb.AppendLine("<td>$(ConvertTo-Html ((@($r.MemberOfDisplay)) -join '; '))</td>")
            [void]$sb.AppendLine("<td>$(ConvertTo-Html $r.Description)</td>")
            [void]$sb.AppendLine("<td>$reasons</td>")
            [void]$sb.AppendLine("<td>$(ConvertTo-Html "$($r.GroupScope)/$($r.GroupCategory)")</td>")
            [void]$sb.AppendLine('</tr>')
        }
        [void]$sb.AppendLine('</table>')
    }
    [void]$sb.AppendLine('</body></html>')
    Set-Content -LiteralPath $Path -Value $sb.ToString() -Encoding UTF8
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path ./tests/Write-HtmlReport.Tests.ps1 -Output Detailed"`
Expected: 1 test passes.

- [ ] **Step 5: Commit**

```bash
git add src/Report/Write-HtmlReport.ps1 tests/Write-HtmlReport.Tests.ps1
git commit -m "feat: add Write-HtmlReport"
```

---

## Task 16: Write-ConsoleSummary

**Files:**
- Create: `src/Report/Write-ConsoleSummary.ps1`
- Test: `tests/Write-ConsoleSummary.Tests.ps1`

- [ ] **Step 1: Write the failing test**

```powershell
BeforeAll {
    . "$PSScriptRoot/_TestHelpers.ps1"
    $script:results = @(
        [pscustomobject]@{ Domain='corp'; Confidence='High';  Reasons=@([pscustomobject]@{Pattern='NameKeyword';Value='Acme'}) }
        [pscustomobject]@{ Domain='corp'; Confidence='Low';   Reasons=@([pscustomobject]@{Pattern='MemberVendorUser';Value='x'}) }
        [pscustomobject]@{ Domain='sub';  Confidence='Medium';Reasons=@([pscustomobject]@{Pattern='DescriptionKeyword';Value='Acme'}) }
    )
    $script:summary = [pscustomobject]@{ TotalGroups=3; FailedDomains=@('dead.example.com'); Warnings=@('one issue'); GeneratedAt='2026-06-05' }
}

Describe 'Write-ConsoleSummary' {
    It 'returns summary lines covering domains, bands, reasons, and failures' {
        $lines = @(Write-ConsoleSummary -Results $results -Summary $summary -AsString)
        ($lines -join "`n") | Should -Match 'corp'
        ($lines -join "`n") | Should -Match 'High'
        ($lines -join "`n") | Should -Match 'NameKeyword'
        ($lines -join "`n") | Should -Match 'dead.example.com'
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path ./tests/Write-ConsoleSummary.Tests.ps1 -Output Detailed"`
Expected: FAIL — function not recognized.

- [ ] **Step 3: Write the implementation** `src/Report/Write-ConsoleSummary.ps1`

```powershell
function Write-ConsoleSummary {
    [CmdletBinding()]
    param([object[]]$Results, [object]$Summary, [switch]$AsString)
    $lines = @()
    $lines += '=== AD Vendor Group Audit Summary ==='
    $lines += "Generated:       $($Summary.GeneratedAt)"
    $lines += "Groups reported: $(@($Results).Count)"
    $lines += ''
    $lines += 'By domain:'
    foreach ($g in ($Results | Group-Object Domain | Sort-Object Name)) {
        $lines += ("  {0,-30} {1}" -f $g.Name, $g.Count)
    }
    $lines += ''
    $lines += 'By confidence:'
    foreach ($band in @('Confirmed','High','Medium','Low')) {
        $n = @($Results | Where-Object Confidence -eq $band).Count
        $lines += ("  {0,-12} {1}" -f $band, $n)
    }
    $lines += ''
    $lines += 'By match reason:'
    $reasonCounts = @{}
    foreach ($r in $Results) {
        foreach ($reason in @($r.Reasons)) {
            if ($null -eq $reason) { continue }
            if (-not $reasonCounts.ContainsKey($reason.Pattern)) { $reasonCounts[$reason.Pattern] = 0 }
            $reasonCounts[$reason.Pattern]++
        }
    }
    foreach ($k in ($reasonCounts.Keys | Sort-Object)) {
        $lines += ("  {0,-20} {1}" -f $k, $reasonCounts[$k])
    }
    if (@($Summary.FailedDomains).Count) {
        $lines += ''
        $lines += 'Failed domains (not audited):'
        foreach ($d in $Summary.FailedDomains) { $lines += "  $d" }
    }
    if (@($Summary.Warnings).Count) {
        $lines += ''
        $lines += "Warnings: $(@($Summary.Warnings).Count) (see HTML report)"
    }

    if ($AsString) { return $lines }
    $lines | ForEach-Object { Write-Host $_ }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path ./tests/Write-ConsoleSummary.Tests.ps1 -Output Detailed"`
Expected: 1 test passes.

- [ ] **Step 5: Commit**

```bash
git add src/Report/Write-ConsoleSummary.ps1 tests/Write-ConsoleSummary.Tests.ps1
git commit -m "feat: add Write-ConsoleSummary"
```

---

## Task 17: Invoke-AdVendorGroupAudit (public orchestrator) + runner

**Files:**
- Create: `src/Invoke-AdVendorGroupAudit.ps1`
- Create: `Invoke-AdVendorGroupAudit.ps1` (repo-root runner)
- Test: `tests/Invoke-AdVendorGroupAudit.Tests.ps1`

> The public function wires the pipeline: read input → build key sets → `Get-AdAuditData` → `Find-CandidateGroups` → `Expand-VendorGroupClosure` → `Select-AuditResults` → `Resolve-ResultDisplay` → writers. The integration test mocks `Get-AdAuditData` so no live AD is needed.

- [ ] **Step 1: Write the failing test**

```powershell
BeforeAll {
    . "$PSScriptRoot/_TestHelpers.ps1"
    $script:tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("int_" + [guid]::NewGuid())
    New-Item -ItemType Directory -Path $script:tmp | Out-Null
    Set-Content "$tmp/users.csv"   "SamAccountName,DisplayName`njsmith,John Smith"
    Set-Content "$tmp/domains.csv" "Domain`ncorp.example.com"
    Set-Content "$tmp/keywords.csv" "Keyword`nAcme"
    Set-Content "$tmp/known.csv"   "Domain,Identity"
    Set-Content "$tmp/exclude.csv" "Domain,Identity"
}
AfterAll { Remove-Item -Recurse -Force $script:tmp -ErrorAction SilentlyContinue }

Describe 'Invoke-AdVendorGroupAudit' {
    BeforeAll {
        Mock -CommandName Get-AdAuditData -MockWith {
            [pscustomobject]@{
                Groups = @(
                    [pscustomobject]@{ Domain='corp.example.com'; Name='Acme Admins'
                        DistinguishedName='CN=Acme Admins,OU=Groups,DC=corp,DC=example,DC=com'
                        Description='Acme app'; Info=''; ManagedBy=''; Member=@(); MemberOf=@()
                        GroupScope='Global'; GroupCategory='Security'; Mail=$null; AdminCount=$null
                        WhenCreated=$null; WhenChanged=$null }
                )
                VendorUsers   = @()
                DnIndex       = @{}
                FailedDomains = @()
                Warnings      = @()
            }
        }
    }
    It 'produces a CSV report containing the discovered group' {
        $out = Join-Path $tmp 'reports'
        Invoke-AdVendorGroupAudit -UsersCsv "$tmp/users.csv" -DomainsCsv "$tmp/domains.csv" `
            -KeywordsCsv "$tmp/keywords.csv" -KnownGroupsCsv "$tmp/known.csv" -ExcludeGroupsCsv "$tmp/exclude.csv" `
            -OutputDirectory $out -Formats @('Csv')
        $csv = Get-ChildItem $out -Filter '*.csv' | Select-Object -First 1
        $csv | Should -Not -BeNullOrEmpty
        (Import-Csv $csv.FullName)[0].Name | Should -Be 'Acme Admins'
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path ./tests/Invoke-AdVendorGroupAudit.Tests.ps1 -Output Detailed"`
Expected: FAIL — function not recognized.

- [ ] **Step 3: Write the implementation** `src/Invoke-AdVendorGroupAudit.ps1`

```powershell
function Invoke-AdVendorGroupAudit {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$UsersCsv,
        [Parameter(Mandatory)][string]$DomainsCsv,
        [Parameter(Mandatory)][string]$KeywordsCsv,
        [Parameter(Mandatory)][string]$KnownGroupsCsv,
        [Parameter(Mandatory)][string]$ExcludeGroupsCsv,
        [Parameter(Mandatory)][string]$OutputDirectory,
        [ValidateSet('Csv','Html','Console')][string[]]$Formats = @('Csv','Html','Console'),
        [System.Management.Automation.PSCredential]$Credential,
        [int]$MaxIterations = 25,
        [switch]$SecurityGroupsOnly,
        [ValidateSet('Low','Medium','High','Confirmed')][string]$MinimumConfidence = 'Low'
    )

    $inputData = Read-AuditInput -UsersCsv $UsersCsv -DomainsCsv $DomainsCsv -KeywordsCsv $KeywordsCsv `
        -KnownGroupsCsv $KnownGroupsCsv -ExcludeGroupsCsv $ExcludeGroupsCsv

    $knownKeys = @{}
    foreach ($k in $inputData.KnownGroups) { $knownKeys[("{0}|{1}" -f $k.Domain, $k.Identity).ToLower()] = $true }
    $excludeKeys = @{}
    foreach ($e in $inputData.ExcludeGroups) { $excludeKeys[("{0}|{1}" -f $e.Domain, $e.Identity).ToLower()] = $true }

    if (-not (Test-Path -LiteralPath $OutputDirectory)) {
        New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
    }

    $data = Get-AdAuditData -InputData $inputData -Credential $Credential

    $groups = $data.Groups
    if ($SecurityGroupsOnly) { $groups = @($groups | Where-Object { "$($_.GroupCategory)" -eq 'Security' }) }

    $candidates = Find-CandidateGroups -Groups $groups -Keywords $inputData.Keywords `
        -VendorUsers $data.VendorUsers -KnownKeys $knownKeys -ExcludeKeys $excludeKeys
    $candidates = Expand-VendorGroupClosure -Results $candidates -MaxIterations $MaxIterations
    $selected   = Select-AuditResults -Results $candidates -MinimumConfidence $MinimumConfidence
    $selected   = Resolve-ResultDisplay -Results $selected -DnIndex $data.DnIndex -VendorUsers $data.VendorUsers
    $selected   = @($selected | Sort-Object @{ Expression = {
        switch ($_.Confidence) { 'Confirmed' {0} 'High' {1} 'Medium' {2} 'Low' {3} default {4} } } }, Domain, Name)

    $summary = [pscustomobject]@{
        TotalGroups   = @($selected).Count
        FailedDomains = $data.FailedDomains
        Warnings      = $data.Warnings
        GeneratedAt   = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    }

    if ($Formats -contains 'Csv') {
        Write-CsvReport -Results $selected -Path (Join-Path $OutputDirectory 'vendor-group-audit.csv')
    }
    if ($Formats -contains 'Html') {
        Write-HtmlReport -Results $selected -Summary $summary -Path (Join-Path $OutputDirectory 'vendor-group-audit.html')
    }
    if ($Formats -contains 'Console') {
        Write-ConsoleSummary -Results $selected -Summary $summary
    }

    [pscustomobject]@{ Results = $selected; Summary = $summary }
}
```

- [ ] **Step 4: Create the repo-root runner** `Invoke-AdVendorGroupAudit.ps1`

```powershell
<#
.SYNOPSIS
  Runner for the AD Vendor Group Audit. Imports the module and invokes the audit.
.EXAMPLE
  ./Invoke-AdVendorGroupAudit.ps1 -UsersCsv samples/users.csv -DomainsCsv samples/domains.csv `
    -KeywordsCsv samples/keywords.csv -KnownGroupsCsv samples/known.csv `
    -ExcludeGroupsCsv samples/exclude.csv -OutputDirectory ./out
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$UsersCsv,
    [Parameter(Mandatory)][string]$DomainsCsv,
    [Parameter(Mandatory)][string]$KeywordsCsv,
    [Parameter(Mandatory)][string]$KnownGroupsCsv,
    [Parameter(Mandatory)][string]$ExcludeGroupsCsv,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [ValidateSet('Csv','Html','Console')][string[]]$Formats = @('Csv','Html','Console'),
    [System.Management.Automation.PSCredential]$Credential,
    [int]$MaxIterations = 25,
    [switch]$SecurityGroupsOnly,
    [ValidateSet('Low','Medium','High','Confirmed')][string]$MinimumConfidence = 'Low'
)
Import-Module (Join-Path $PSScriptRoot 'AdVendorGroupAudit.psd1') -Force
Invoke-AdVendorGroupAudit @PSBoundParameters | Out-Null
```

- [ ] **Step 5: Run test to verify it passes**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path ./tests/Invoke-AdVendorGroupAudit.Tests.ps1 -Output Detailed"`
Expected: 1 test passes.

- [ ] **Step 6: Commit**

```bash
git add src/Invoke-AdVendorGroupAudit.ps1 Invoke-AdVendorGroupAudit.ps1 tests/Invoke-AdVendorGroupAudit.Tests.ps1
git commit -m "feat: add Invoke-AdVendorGroupAudit orchestrator and runner"
```

---

## Task 18: Sample inputs, README, full suite + lint

**Files:**
- Create: `samples/users.csv`, `samples/domains.csv`, `samples/keywords.csv`, `samples/known.csv`, `samples/exclude.csv`
- Create: `README.md`
- Modify: remove `src/.gitkeep`, `samples/.gitkeep` if present

- [ ] **Step 1: Create the sample CSVs**

`samples/users.csv`:
```
SamAccountName,DisplayName
jsmith,John Smith
ajones,Alice Jones
```
`samples/domains.csv`:
```
Domain,Server,Name
corp.example.com,dc1.corp.example.com,Corp
sub.example.com,,Sub
```
`samples/keywords.csv`:
```
Keyword
Acme
ACME Corp
Acme Managed Services
```
`samples/known.csv`:
```
Domain,Identity
corp.example.com,Acme Admins
```
`samples/exclude.csv`:
```
Domain,Identity
corp.example.com,Domain Users
```

- [ ] **Step 2: Write `README.md`**

````markdown
# AD Vendor Group Audit

Audits Active Directory across multiple domains to discover the groups belonging to
or used by a vendor, and produces CSV, HTML, and console reports with
confidence-scored match reasons.

## Requirements

- Windows PowerShell 5.1
- RSAT ActiveDirectory module (`Import-Module ActiveDirectory`)
- Read access to each domain being audited

## Inputs (one CSV per list)

| File | Columns |
|------|---------|
| users.csv | `SamAccountName`, `DisplayName` (optional) |
| domains.csv | `Domain`, `Server` (optional), `Name` (optional) |
| keywords.csv | `Keyword` |
| known.csv | `Domain`, `Identity` |
| exclude.csv | `Domain`, `Identity` |

## Usage

```powershell
./Invoke-AdVendorGroupAudit.ps1 `
    -UsersCsv samples/users.csv -DomainsCsv samples/domains.csv `
    -KeywordsCsv samples/keywords.csv -KnownGroupsCsv samples/known.csv `
    -ExcludeGroupsCsv samples/exclude.csv -OutputDirectory ./out
```

Options: `-Formats Csv,Html,Console`, `-Credential`, `-MaxIterations 25`,
`-SecurityGroupsOnly`, `-MinimumConfidence Low|Medium|High|Confirmed`.

## How groups are found

Each group is matched against these patterns; each match contributes to a confidence
score (High / Medium / Low, or Confirmed for known groups):

- Vendor keyword in the group **name** or its **container/OU** (strong)
- **managedBy/owner** is a vendor user (strong)
- Vendor keyword or a vendor user's name/ID in the **description/info** (medium)
- Group **contains another vendor group** — propagated to closure (medium)
- A vendor user is a direct **member** (weak; multiple members add up)

Members flagged with a leading `*` in reports are vendor users.

## Output

- `vendor-group-audit.csv` — one row per group, with a `MatchReasons` column
- `vendor-group-audit.html` — grouped by domain and confidence, reasons highlighted
- Console summary — counts per domain / band / reason, plus failed domains

## Development

Run the test suite (Pester 5):

```bash
pwsh -NoProfile -Command "Invoke-Pester -Path ./tests -Output Detailed"
```
````

- [ ] **Step 3: Run the FULL test suite**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path ./tests -Output Detailed"`
Expected: all tests across every file pass.

- [ ] **Step 4: Run PSScriptAnalyzer and fix any Error/Warning**

Run:
```bash
pwsh -NoProfile -Command "if (-not (Get-Module -ListAvailable PSScriptAnalyzer)) { Install-Module PSScriptAnalyzer -Scope CurrentUser -Force }; Invoke-ScriptAnalyzer -Path . -Recurse -Settings ./PSScriptAnalyzerSettings.psd1"
```
Expected: no Error/Warning output. Fix any that appear, then re-run.

- [ ] **Step 5: Commit**

```bash
git add samples/ README.md
git rm -f src/.gitkeep samples/.gitkeep 2>/dev/null || true
git commit -m "docs: add README and sample inputs; finalize suite"
```

---

## Self-review notes (already reconciled)

- **Spec coverage:** input layer (T2), identity tokens incl. AD-resolved + CSV alternates (T3, T13), all eight match patterns (T6–T8), keyword in name/container/description/info (T6–T7), owner & member (T8), scoring + banding (T9), known/exclude handling (T10), nested closure with cap + cycles (T11), cross-domain resolution via `DnIndex` (T12–T13), security-only filter & min-confidence (T17), CSV/HTML/console writers separated and swappable (T14–T16), per-domain failure handling (T13), README + samples (T18). All spec sections map to a task.
- **Type consistency:** result field names (`Reasons`, `Score`, `Confidence`, `IsKnown`, `Source`, `Member`, `MemberOf`, then `Owner`/`Members`/`MemberOfDisplay`) are used identically across T10–T17. `DnIndex` keys are always lowercased. Pattern names (`NameKeyword`, `ContainerKeyword`, `Owner`, `DescriptionUser`, `DescriptionKeyword`, `NestedVendorGroup`, `MemberVendorUser`) match between matchers (T6–T8, T11) and `Get-MatchConfidence` weights (T9).
- **No placeholders:** every step ships complete, runnable code and exact commands.
