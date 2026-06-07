function Get-AdDiscoveryData {
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
    $sidSeen      = @{}   # objectSid string -> already resolved (dedupe same physical user across domains)

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
            # Do NOT continue — vendor-user resolution below is independent of group enumeration.
        }

        foreach ($csvUser in $InputData.Users) {
            $sam = $csvUser.SamAccountName
            if ([string]::IsNullOrWhiteSpace($sam)) { continue }
            if ($sam -match "['()*\\/]") {
                $warnings += "Skipping user with suspicious SamAccountName '$sam'"
                continue
            }
            try {
                $samFilterValue = $sam
                $u = Get-ADUser @common -Filter { SamAccountName -eq $samFilterValue } -Properties $userProps
            } catch {
                $warnings += "Lookup failed for user '$sam' in '$($d.Domain)': $($_.Exception.Message)"
                continue
            }
            if (-not $u) { continue }
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
