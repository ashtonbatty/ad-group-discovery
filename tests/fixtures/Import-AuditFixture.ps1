<#
.SYNOPSIS
    Loader bridge for the audit fixture. Turns directory.json + audit-input/*.csv
    into the exact object shape that Get-AdAuditData produces, so the rest of the
    engine pipeline (Find-CandidateGroups -> Expand-VendorGroupClosure ->
    Select-AuditResults -> Resolve-ResultDisplay -> report writers) can run over
    the fixture with NO live Active Directory and NO Get-AD* mocking.

.NOTES
    Requires the module's src functions to be loaded first (they provide
    ConvertTo-IdentityTokens and Resolve-DirectoryIndex). In a test or demo,
    dot-source tests/_TestHelpers.ps1 before calling Get-FixtureAuditData.
#>

function Import-AuditFixtureDirectory {
    [CmdletBinding()]
    param([string]$Path = (Join-Path $PSScriptRoot 'directory.json'))
    Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

function Get-FixtureAuditData {
    # Returns a Get-AdAuditData-shaped object built from the fixture:
    #   Groups, VendorUsers (with Tokens), DnIndex, FailedDomains, Warnings
    # plus InputData (the parsed audit-input CSVs) for convenience.
    [CmdletBinding()]
    param([string]$FixtureDir = $PSScriptRoot)

    $dir = Import-AuditFixtureDirectory -Path (Join-Path $FixtureDir 'directory.json')

    $inDir = Join-Path $FixtureDir 'audit-input'
    $inputData = Read-AuditInput `
        -UsersCsv        (Join-Path $inDir 'users.csv') `
        -DomainsCsv      (Join-Path $inDir 'domains.csv') `
        -KeywordsCsv     (Join-Path $inDir 'keywords.csv') `
        -KnownGroupsCsv  (Join-Path $inDir 'known.csv') `
        -ExcludeGroupsCsv (Join-Path $inDir 'exclude.csv')

    # The audit targets the users listed in users.csv; resolve each against the
    # directory and build identity tokens (AD attributes + CSV display name).
    $auditBySam = @{}
    foreach ($cu in $inputData.Users) { $auditBySam[$cu.SamAccountName.ToLower()] = $cu }

    $vendorUsers = foreach ($u in $dir.Users) {
        $key = $u.SamAccountName.ToLower()
        if (-not $auditBySam.ContainsKey($key)) { continue }
        $csv = $auditBySam[$key]
        $tokens = ConvertTo-IdentityTokens -SamAccountName $u.SamAccountName -DisplayName $u.DisplayName `
            -GivenName $u.GivenName -Surname $u.Surname -Cn $u.DisplayName -Name $u.DisplayName `
            -Upn $u.UserPrincipalName -Mail $u.Mail -CsvDisplayName $csv.DisplayName
        [pscustomobject]@{
            SamAccountName    = $u.SamAccountName
            DisplayName       = $u.DisplayName
            Sid               = $u.Sid
            DistinguishedName = $u.DistinguishedName
            Tokens            = $tokens
        }
    }
    $vendorUsers = @($vendorUsers)
    $groups = @($dir.Groups)

    [pscustomobject]@{
        Groups        = $groups
        VendorUsers   = $vendorUsers
        DnIndex       = (Resolve-DirectoryIndex -VendorUsers $vendorUsers -Groups $groups)
        FailedDomains = @()
        Warnings      = @()
        InputData     = $inputData
    }
}
