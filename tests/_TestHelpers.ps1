# Dot-source all source functions so tests can call them directly (no module import needed).
$root = Split-Path -Parent $PSScriptRoot
Get-ChildItem -Path (Join-Path $root 'src') -Recurse -Filter '*.ps1' -ErrorAction SilentlyContinue |
    ForEach-Object { . $_.FullName }

# Canonical vendor-user fixture shared across unit tests.
function New-TestVendorUser {
    param([switch]$WithTokens)
    $u = [pscustomobject]@{
        SamAccountName    = 'jsmith'
        DisplayName       = 'John Smith'
        Sid               = 'S-1-5-21-1-2-3-1001'
        DistinguishedName = 'CN=John Smith,OU=Vendor,DC=corp,DC=example,DC=com'
    }
    if ($WithTokens) { $u | Add-Member -NotePropertyName Tokens -NotePropertyValue @('jsmith','John Smith') }
    $u
}

# Canonical raw-group fixture (the shape Get-AdDiscoveryData emits).
function New-TestGroup {
    param(
        [string]$Name, [string]$Dn, [string]$Description = '', [string]$ManagedBy = '',
        [string[]]$Member = @(), [string]$Domain = 'corp.example.com'
    )
    [pscustomobject]@{ Domain = $Domain; Name = $Name; DistinguishedName = $Dn
        Description = $Description; Info = ''; ManagedBy = $ManagedBy; Member = $Member; MemberOf = @()
        GroupScope = 'Global'; GroupCategory = 'Security'; Mail = $null; AdminCount = $null
        WhenCreated = $null; WhenChanged = $null }
}

# Unique scratch directory; callers remove it in AfterAll.
function New-TestTempDir {
    param([string]$Prefix = 'vadg')
    $p = Join-Path ([System.IO.Path]::GetTempPath()) ($Prefix + '_' + [guid]::NewGuid())
    New-Item -ItemType Directory -Path $p | Out-Null
    $p
}

# Stub AD cmdlets so Pester Mock can intercept them on non-Windows / no-AD test runners.
if (-not (Get-Command Get-ADGroup  -ErrorAction SilentlyContinue)) {
    function Get-ADGroup  { [CmdletBinding()] param([Parameter(ValueFromRemainingArguments)]$RemainingArgs) }
}
if (-not (Get-Command Get-ADUser   -ErrorAction SilentlyContinue)) {
    function Get-ADUser   { [CmdletBinding()] param([Parameter(ValueFromRemainingArguments)]$RemainingArgs) }
}
