# Dot-source all source functions so tests can call them directly (no module import needed).
$root = Split-Path -Parent $PSScriptRoot
Get-ChildItem -Path (Join-Path $root 'src') -Recurse -Filter '*.ps1' -ErrorAction SilentlyContinue |
    ForEach-Object { . $_.FullName }

# Canonical vendor-user fixture shared across unit tests.
function New-TestVendorUser {
    param([switch]$WithTokens)
    $u = [pscustomobject]@{
        SamAccountName    = 'jsmith'
        UUserId           = 'U12345'
        DisplayName       = 'John Smith'
        Sid               = 'S-1-5-21-1-2-3-1001'
        DistinguishedName = 'CN=John Smith,OU=Vendor,DC=corp,DC=example,DC=com'
    }
    # Longest-first, matching the ConvertTo-IdentityTokens ordering contract.
    if ($WithTokens) { $u | Add-Member -NotePropertyName Tokens -NotePropertyValue @('jsmith@vendor.com','jsmith','U12345') }
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
# Parameters mirror the RSAT cmdlets' (subset we use) so Mock -ParameterFilter can bind them.
if (-not (Get-Command Get-ADGroup  -ErrorAction SilentlyContinue)) {
    function Get-ADGroup  {
        [CmdletBinding()]
        param($Identity, $Filter, [string]$LDAPFilter, [string[]]$Properties, [string]$Server,
              [string]$SearchBase,
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
if (-not (Get-Command Get-ADObject -ErrorAction SilentlyContinue)) {
    function Get-ADObject {
        [CmdletBinding()]
        param($Identity, [string]$LDAPFilter, [string[]]$Properties, [string]$Server,
              [System.Management.Automation.PSCredential]$Credential)
    }
}
if (-not (Get-Command Get-ADOrganizationalUnit -ErrorAction SilentlyContinue)) {
    function Get-ADOrganizationalUnit {
        [CmdletBinding()]
        param($Filter, [string]$LDAPFilter, [string[]]$Properties, [string]$Server,
              [System.Management.Automation.PSCredential]$Credential)
    }
}
