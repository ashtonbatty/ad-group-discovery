function Get-AdAuditData {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$InputData,
        [System.Management.Automation.PSCredential]$Credential
    )
    $groupProps = @('description','info','managedBy','member','memberOf','groupScope',
                    'groupCategory','mail','adminCount','whenCreated','whenChanged')
    $userProps  = @('displayName','givenName','sn','cn','name','userPrincipalName','mail','objectSid')

    $allGroups    = New-Object System.Collections.Generic.List[object]
    $vendorUsers  = New-Object System.Collections.Generic.List[object]
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
                $allGroups.Add([pscustomobject]@{
                    Domain = $d.Domain; Name = $g.Name; DistinguishedName = $g.DistinguishedName
                    Description = $g.description; Info = $g.info; ManagedBy = $g.managedBy
                    Member = @($g.member); MemberOf = @($g.memberof)
                    GroupScope = "$($g.GroupScope)"; GroupCategory = "$($g.GroupCategory)"
                    Mail = $g.mail; AdminCount = $g.adminCount
                    WhenCreated = $g.whenCreated; WhenChanged = $g.whenChanged
                })
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
            $vendorUsers.Add([pscustomobject]@{
                SamAccountName = $u.SamAccountName
                DisplayName    = if ($u.displayName) { $u.displayName } else { $u.Name }
                Sid            = "$($u.objectSid)"
                DistinguishedName = $u.DistinguishedName
                Tokens         = $tokens
            })
        }
    }

    $groupsArr = $allGroups.ToArray()
    $usersArr  = $vendorUsers.ToArray()
    [pscustomobject]@{
        Groups        = $groupsArr
        VendorUsers   = $usersArr
        DnIndex       = (Resolve-DirectoryIndex -VendorUsers $usersArr -Groups $groupsArr)
        FailedDomains = $failedDomains
        Warnings      = $warnings
    }
}
