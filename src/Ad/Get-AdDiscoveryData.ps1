function Get-AdDiscoveryData {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$InputData,
        [System.Management.Automation.PSCredential]$Credential
    )
    $groupProps = @('description','info','managedBy','member','memberOf','groupScope',
                    'groupCategory','mail','adminCount','whenCreated','whenChanged')
    $userProps  = @('displayName','givenName','sn','cn','name','userPrincipalName','mail','objectSid')
    $samBatchSize = 200   # names per OR'd -LDAPFilter; keeps each filter well under LDAP size limits

    $allGroups    = New-Object System.Collections.Generic.List[object]
    $vendorUsers  = New-Object System.Collections.Generic.List[object]
    $failedDomains = New-Object System.Collections.Generic.List[string]
    $warnings      = New-Object System.Collections.Generic.List[string]
    $sidSeen      = @{}   # objectSid string -> already resolved (dedupe same physical user across domains)

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

    $domainTotal = @($InputData.Domains).Count
    $domainIndex = 0
    foreach ($d in $InputData.Domains) {
        $domainIndex++
        Write-Host "  [$domainIndex/$domainTotal] $($d.Domain)..."
        $server = if ($d.Server) { $d.Server } else { $d.Domain }
        $common = @{ Server = $server; ErrorAction = 'Stop' }
        if ($Credential) { $common['Credential'] = $Credential }

        $domainGroupCount = 0
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
                $domainGroupCount++
            }
        } catch {
            $failedDomains.Add($d.Domain)
            $warnings.Add("Failed to query groups in '$($d.Domain)': $($_.Exception.Message)")
            # Do NOT continue — vendor-user resolution below is independent of group enumeration.
        }

        $domainUserCount = 0
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
                $domainUserCount++
            }
        }
        Write-Host "  [$domainIndex/$domainTotal] $($d.Domain) — $domainGroupCount groups, $domainUserCount vendor users"
    }

    $groupsArr = $allGroups.ToArray()
    $usersArr  = $vendorUsers.ToArray()
    [pscustomobject]@{
        Groups        = $groupsArr
        VendorUsers   = $usersArr
        DnIndex       = (Resolve-DirectoryIndex -VendorUsers $usersArr -Groups $groupsArr)
        FailedDomains = $failedDomains.ToArray()
        Warnings      = $warnings.ToArray()
    }
}
