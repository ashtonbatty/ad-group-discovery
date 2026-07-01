<#
.SYNOPSIS
    Loader bridge for the discovery fixture. Turns directory.json + discovery-input/*.csv
    into the exact object shape that Get-AdDiscoveryData produces, so the rest of the
    engine pipeline (Find-CandidateGroups -> Expand-VendorGroupClosure ->
    Select-DiscoveryResults -> Resolve-ResultDisplay -> report writers) can run over
    the fixture with NO live Active Directory and NO Get-AD* mocking.

.NOTES
    Requires the module's src functions to be loaded first (they provide
    ConvertTo-IdentityTokens and Resolve-DirectoryIndex). In a test or demo,
    dot-source tests/_TestHelpers.ps1 before calling Get-FixtureDiscoveryData.
#>

function Import-DiscoveryFixtureDirectory {
    [CmdletBinding()]
    param([string]$Path = (Join-Path $PSScriptRoot 'directory.json'))
    Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

function Get-FixtureDiscoveryData {
    # Returns a Get-AdDiscoveryData-shaped object built from the fixture:
    #   Groups, VendorUsers (with Tokens), DnIndex, FailedDomains, Warnings
    # plus InputData (the parsed discovery-input CSVs) for convenience.
    [CmdletBinding()]
    param([string]$FixtureDir = $PSScriptRoot)

    $dir = Import-DiscoveryFixtureDirectory -Path (Join-Path $FixtureDir 'directory.json')

    $inDir = Join-Path $FixtureDir 'discovery-input'
    $inputData = Read-DiscoveryInput `
        -UsersCsv        (Join-Path $inDir 'users.csv') `
        -DomainsCsv      (Join-Path $inDir 'domains.csv') `
        -KeywordsCsv     (Join-Path $inDir 'keywords.csv') `
        -KnownGroupsCsv  (Join-Path $inDir 'known.csv') `
        -ExcludeGroupsCsv (Join-Path $inDir 'exclude.csv')

    # The discovery targets the users listed in users.csv; resolve each against the
    # directory and build description tokens from sam account name + optional
    # UUserId + AD mail.
    $discoveryBySam = @{}
    foreach ($cu in $inputData.Users) { $discoveryBySam[$cu.SamAccountName.ToLower()] = $cu }

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

    $vendorUsers = foreach ($u in $dir.Users) {
        $key = $u.SamAccountName.ToLower()
        if (-not $discoveryBySam.ContainsKey($key)) { continue }
        $csvUser = $discoveryBySam[$key]
        $tokens = ConvertTo-IdentityTokens -SamAccountName $u.SamAccountName -UUserId $csvUser.UUserId -Mail $u.Mail
        [pscustomobject]@{
            SamAccountName         = $u.SamAccountName
            UUserId                = $csvUser.UUserId
            DisplayName            = $u.DisplayName
            Mail                   = $u.Mail
            Sid                    = $u.Sid
            DistinguishedName      = $u.DistinguishedName
            Tokens                 = $tokens
            Domain                 = $u.Domain
            MemberOf               = @($memberOfByUserDn[$u.DistinguishedName.ToLower()])
            Enabled                = $u.Enabled
            LockedOut              = $u.LockedOut
            Description            = $u.Description
            AccountExpirationDate  = $u.AccountExpirationDate
            LastLogonDate          = $u.LastLogonDate
            PasswordLastSet        = $u.PasswordLastSet
            BadLogonCount          = $u.BadLogonCount
            PasswordNeverExpires   = $u.PasswordNeverExpires
            PasswordExpiryComputed = $u.PasswordExpiryComputed
        }
    }
    $vendorUsers = @($vendorUsers)
    $groups = @($dir.Groups)
    $objectByDn = @{}
    foreach ($u in $dir.Users) {
        $objectByDn[$u.DistinguishedName.ToLower()] = [pscustomobject]@{
            DistinguishedName = $u.DistinguishedName
            SamAccountName    = $u.SamAccountName
            DisplayName       = $u.DisplayName
            Name              = $u.DisplayName
            ObjectClass       = 'user'
        }
    }
    foreach ($g in $groups) {
        $objectByDn[$g.DistinguishedName.ToLower()] = [pscustomobject]@{
            DistinguishedName = $g.DistinguishedName
            SamAccountName    = ''
            DisplayName       = $g.Name
            Name              = $g.Name
            ObjectClass       = 'group'
        }
    }
    foreach ($g in $groups) {
        $memberObjects = foreach ($memberDn in @($g.Member)) {
            $key = $memberDn.ToLower()
            if ($objectByDn.ContainsKey($key)) { $objectByDn[$key] }
        }
        $g | Add-Member -NotePropertyName MemberDirectoryObjects -NotePropertyValue @($memberObjects) -Force
    }

    [pscustomobject]@{
        Groups        = $groups
        VendorUsers   = $vendorUsers
        DnIndex       = (Resolve-DirectoryIndex -VendorUsers $vendorUsers -Groups $groups)
        FailedDomains = @()
        Warnings      = @()
        InputData     = $inputData
    }
}
