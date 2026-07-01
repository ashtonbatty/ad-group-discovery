function Get-AdDiscoveryData {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$InputData,
        [System.Management.Automation.PSCredential]$Credential,
        [switch]$SecurityGroupsOnly
    )

    $groupMetadataProps = @('description','info','managedBy','groupScope',
                            'groupCategory','mail','adminCount','whenCreated','whenChanged')
    $groupProps = @($groupMetadataProps + @('member','memberOf'))
    $memberObjectProps = @('sAMAccountName','displayName','name','objectClass')
    $userProps  = @('displayName','givenName','sn','cn','name','userPrincipalName','mail','objectSid','memberOf',
                    'enabled','lockedOut','description','accountExpirationDate','lastLogonDate',
                    'passwordLastSet','badLogonCount','passwordNeverExpires','msDS-UserPasswordExpiryTimeComputed')
    $samBatchSize = 200   # names per OR'd -LDAPFilter; keeps each filter well under LDAP size limits
    $ldapBatchSize = 40   # DNs/tokens per OR'd group search
    $securityGroupClause = '(groupType:1.2.840.113556.1.4.803:=2147483648)'

    function ConvertTo-DomainDistinguishedName {
        param([Parameter(Mandatory)][string]$Domain)
        (($Domain -split '\.') | ForEach-Object { 'DC=' + (ConvertTo-LdapFilterValue -Value $_) }) -join ','
    }

    function Test-DistinguishedNameInDomain {
        param([string]$DistinguishedName, [string]$DomainDn)
        if ([string]::IsNullOrWhiteSpace($DistinguishedName)) { return $false }
        if ([string]::IsNullOrWhiteSpace($DomainDn)) { return $false }
        $DistinguishedName.EndsWith($DomainDn, [System.StringComparison]::OrdinalIgnoreCase)
    }

    function New-LdapAndFilter {
        param([string[]]$Clauses)
        $active = @($Clauses | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if ($active.Count -eq 0) { return '' }
        if ($active.Count -eq 1) { return $active[0] }
        "(&$($active -join ''))"
    }

    function New-LdapOrFilter {
        param([string[]]$Clauses)
        $active = @($Clauses | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if ($active.Count -eq 0) { return '' }
        if ($active.Count -eq 1) { return $active[0] }
        "(|$($active -join ''))"
    }

    function New-GroupSearchFilter {
        param([string]$Clause)
        $parts = @($Clause)
        if ($SecurityGroupsOnly) { $parts += $securityGroupClause }
        New-LdapAndFilter -Clauses $parts
    }

    function New-ContainsFilter {
        param([Parameter(Mandatory)][string]$Attribute, [Parameter(Mandatory)][string]$Value)
        "($Attribute=*$(ConvertTo-LdapFilterValue -Value $Value)*)"
    }

    function New-ExactFilter {
        param([Parameter(Mandatory)][string]$Attribute, [Parameter(Mandatory)][string]$Value)
        "($Attribute=$(ConvertTo-LdapFilterValue -Value $Value))"
    }

    function Invoke-AdGroupSearch {
        param(
            [Parameter(Mandatory)][hashtable]$Common,
            [Parameter(Mandatory)][string]$Domain,
            [Parameter(Mandatory)][string]$Phase,
            [Parameter(Mandatory)][string]$LDAPFilter,
            [string[]]$Properties,
            [string]$SearchBase,
            [Parameter(Mandatory)][hashtable]$FailedGroupDomain,
            [Parameter(Mandatory)]$Warnings
        )
        if ([string]::IsNullOrWhiteSpace($LDAPFilter)) { return @() }
        $query = @{} + $Common
        $query['LDAPFilter'] = $LDAPFilter
        if ($Properties) { $query['Properties'] = $Properties }
        if (-not [string]::IsNullOrWhiteSpace($SearchBase)) { $query['SearchBase'] = $SearchBase }
        try {
            return @(Get-ADGroup @query)
        } catch {
            $FailedGroupDomain[$Domain] = $true
            $Warnings.Add("Group lookup failed in '$Domain' during $Phase`: $($_.Exception.Message)")
            return @()
        }
    }

    function Invoke-AdOuSearch {
        param(
            [Parameter(Mandatory)][hashtable]$Common,
            [Parameter(Mandatory)][string]$Domain,
            [Parameter(Mandatory)][string]$LDAPFilter,
            [Parameter(Mandatory)][hashtable]$FailedGroupDomain,
            [Parameter(Mandatory)]$Warnings
        )
        if ([string]::IsNullOrWhiteSpace($LDAPFilter)) { return @() }
        $query = @{} + $Common
        $query['LDAPFilter'] = $LDAPFilter
        $query['Properties'] = @('distinguishedName')
        try {
            return @(Get-ADOrganizationalUnit @query)
        } catch {
            $FailedGroupDomain[$Domain] = $true
            $Warnings.Add("OU lookup failed in '$Domain': $($_.Exception.Message)")
            return @()
        }
    }

    function Get-AdGroupByIdentity {
        param(
            [Parameter(Mandatory)][hashtable]$Common,
            [Parameter(Mandatory)][string]$Domain,
            [Parameter(Mandatory)][string]$Identity,
            [string[]]$Properties,
            [Parameter(Mandatory)]$Warnings
        )
        $query = @{} + $Common
        $query['Identity'] = $Identity
        if ($Properties) { $query['Properties'] = $Properties }
        try {
            $group = Get-ADGroup @query
            if ($SecurityGroupsOnly -and $group -and "$($group.GroupCategory)" -and "$($group.GroupCategory)" -ne 'Security') {
                return $null
            }
            return $group
        } catch {
            $Warnings.Add("Group lookup failed in '$Domain' for '$Identity': $($_.Exception.Message)")
            return $null
        }
    }

    function Add-CandidateGroup {
        param(
            [object]$Group,
            [Parameter(Mandatory)][hashtable]$Seen,
            [Parameter(Mandatory)]$List
        )
        if (-not $Group) { return $false }
        $dn = "$($Group.DistinguishedName)"
        if ([string]::IsNullOrWhiteSpace($dn)) { return $false }
        if ($SecurityGroupsOnly -and "$($Group.GroupCategory)" -and "$($Group.GroupCategory)" -ne 'Security') {
            return $false
        }
        $key = $dn.ToLower()
        if ($Seen.ContainsKey($key)) { return $false }
        $Seen[$key] = $dn
        $List.Add($dn)
        return $true
    }

    function Add-CandidateDn {
        param(
            [string]$DistinguishedName,
            [Parameter(Mandatory)][hashtable]$Seen,
            [Parameter(Mandatory)]$List
        )
        if ([string]::IsNullOrWhiteSpace($DistinguishedName)) { return $false }
        $key = $DistinguishedName.ToLower()
        if ($Seen.ContainsKey($key)) { return $false }
        $Seen[$key] = $DistinguishedName
        $List.Add($DistinguishedName)
        return $true
    }

    function Add-GroupsFromSearch {
        param(
            [object[]]$Groups,
            [Parameter(Mandatory)][hashtable]$Seen,
            [Parameter(Mandatory)]$List
        )
        $count = 0
        foreach ($group in @($Groups)) {
            if (Add-CandidateGroup -Group $group -Seen $Seen -List $List) { $count++ }
        }
        return $count
    }

    function Resolve-AdMemberObject {
        param(
            [Parameter(Mandatory)][hashtable]$Common,
            [string]$DistinguishedName,
            [Parameter(Mandatory)][hashtable]$Cache
        )
        if ([string]::IsNullOrWhiteSpace($DistinguishedName)) { return $null }

        $key = $DistinguishedName.ToLower()
        if ($Cache.ContainsKey($key)) { return $Cache[$key] }

        $query = @{} + $Common
        $query['Identity'] = $DistinguishedName
        $query['Properties'] = $memberObjectProps
        try {
            $adObject = Get-ADObject @query
        } catch {
            $adObject = $null
        }

        $objectClass = ''
        if ($adObject) {
            $classes = @($adObject.objectClass)
            if ($classes.Count -gt 0) { $objectClass = [string]$classes[-1] }
        }

        $memberObject = [pscustomobject]@{
            DistinguishedName = $DistinguishedName
            SamAccountName    = if ($adObject) { $adObject.sAMAccountName } else { '' }
            DisplayName       = if ($adObject) { $adObject.displayName } else { '' }
            Name              = if ($adObject) { $adObject.name } else { '' }
            ObjectClass       = $objectClass
        }
        $Cache[$key] = $memberObject
        return $memberObject
    }

    function Get-Batches {
        param([object[]]$Items, [int]$BatchSize)
        $batches = New-Object System.Collections.ArrayList
        for ($i = 0; $i -lt $Items.Count; $i += $BatchSize) {
            $last = [Math]::Min($i + $BatchSize, $Items.Count) - 1
            [void]$batches.Add(@($Items[$i..$last]))
        }
        if ($batches.Count -eq 0) { return @() }
        return ,$batches
    }

    $allGroups     = New-Object System.Collections.Generic.List[object]
    $vendorUsers   = New-Object System.Collections.Generic.List[object]
    $failedDomains = New-Object System.Collections.Generic.List[string]
    $warnings      = New-Object System.Collections.Generic.List[string]
    $sidSeen       = @{}   # objectSid string -> already resolved (dedupe same physical user across domains)
    $failedGroupDomain = @{}
    $memberObjectCache = @{}

    # Validate CSV users once and index them by sam so batched query results can be
    # mapped back to their CSV row for token building.
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
    $domainContexts = New-Object System.Collections.Generic.List[object]
    $domainUserCounts = @{}
    $domainIndex = 0
    foreach ($d in $InputData.Domains) {
        $domainIndex++
        $server = if ($d.Server) { $d.Server } else { $d.Domain }
        $common = @{ Server = $server; ErrorAction = 'Stop' }
        if ($Credential) { $common['Credential'] = $Credential }
        $domainContexts.Add([pscustomobject]@{
            Index    = $domainIndex
            Domain   = $d.Domain
            Server   = $server
            DomainDn = ConvertTo-DomainDistinguishedName -Domain $d.Domain
            Common   = $common
        })

        Write-Host "  [$domainIndex/$domainTotal] $($d.Domain) via $server - resolving vendor users..."
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
                $tokens = ConvertTo-IdentityTokens -SamAccountName $u.SamAccountName -UUserId $csvUser.UUserId -Mail $u.mail
                $vendorUsers.Add([pscustomobject]@{
                    SamAccountName    = $u.SamAccountName
                    UUserId           = $csvUser.UUserId
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
                $domainUserCount++
            }
        }
        $domainUserCounts[$d.Domain] = $domainUserCount
        Write-Host "  [$domainIndex/$domainTotal] $($d.Domain) - resolved $domainUserCount vendor users"
    }

    $allVendorUsers = $vendorUsers.ToArray()
    $keywords = @($InputData.Keywords | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $descriptionUserTokens = @($allVendorUsers | ForEach-Object { $_.Tokens } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)

    foreach ($ctx in $domainContexts) {
        Write-Host "  [$($ctx.Index)/$domainTotal] $($ctx.Domain) - finding candidate groups..."
        $candidateSeen = @{}
        $candidateDns = New-Object System.Collections.Generic.List[string]

        Write-Host "    direct vendor memberships..."
        foreach ($u in $allVendorUsers) {
            foreach ($memberOf in @($u.MemberOf)) {
                if (Test-DistinguishedNameInDomain -DistinguishedName $memberOf -DomainDn $ctx.DomainDn) {
                    [void](Add-CandidateDn -DistinguishedName $memberOf -Seen $candidateSeen -List $candidateDns)
                }
            }
        }
        $memberClauses = New-Object System.Collections.Generic.List[string]
        foreach ($u in $allVendorUsers) {
            if ($u.DistinguishedName) {
                $memberClauses.Add((New-ExactFilter -Attribute 'member' -Value $u.DistinguishedName))
            }
            if ($u.Sid) {
                $fspDn = "CN=$($u.Sid),CN=ForeignSecurityPrincipals,$($ctx.DomainDn)"
                $memberClauses.Add((New-ExactFilter -Attribute 'member' -Value $fspDn))
            }
        }
        foreach ($batch in @(Get-Batches -Items $memberClauses.ToArray() -BatchSize $ldapBatchSize)) {
            $filter = New-GroupSearchFilter -Clause (New-LdapOrFilter -Clauses $batch)
            $groups = Invoke-AdGroupSearch -Common $ctx.Common -Domain $ctx.Domain -Phase 'direct vendor membership' `
                -LDAPFilter $filter -Properties $groupMetadataProps -FailedGroupDomain $failedGroupDomain -Warnings $warnings
            [void](Add-GroupsFromSearch -Groups $groups -Seen $candidateSeen -List $candidateDns)
        }

        if ($keywords.Count -gt 0) {
            Write-Host "    keyword searches..."
            $keywordClauses = New-Object System.Collections.Generic.List[string]
            foreach ($keyword in $keywords) {
                $keywordClauses.Add((New-ContainsFilter -Attribute 'name' -Value $keyword))
                $keywordClauses.Add((New-ContainsFilter -Attribute 'description' -Value $keyword))
                $keywordClauses.Add((New-ContainsFilter -Attribute 'info' -Value $keyword))
            }
            foreach ($batch in @(Get-Batches -Items $keywordClauses.ToArray() -BatchSize $ldapBatchSize)) {
                $filter = New-GroupSearchFilter -Clause (New-LdapOrFilter -Clauses $batch)
                $groups = Invoke-AdGroupSearch -Common $ctx.Common -Domain $ctx.Domain -Phase 'keyword search' `
                    -LDAPFilter $filter -Properties $groupMetadataProps -FailedGroupDomain $failedGroupDomain -Warnings $warnings
                [void](Add-GroupsFromSearch -Groups $groups -Seen $candidateSeen -List $candidateDns)
            }

            Write-Host "    OU keyword searches..."
            $ouClauses = @($keywords | ForEach-Object { New-ContainsFilter -Attribute 'name' -Value $_ })
            $ouFilter = New-LdapOrFilter -Clauses $ouClauses
            $ous = Invoke-AdOuSearch -Common $ctx.Common -Domain $ctx.Domain -LDAPFilter $ouFilter `
                -FailedGroupDomain $failedGroupDomain -Warnings $warnings
            foreach ($ou in @($ous)) {
                if ([string]::IsNullOrWhiteSpace($ou.DistinguishedName)) { continue }
                $filter = New-GroupSearchFilter -Clause '(objectClass=group)'
                $groups = Invoke-AdGroupSearch -Common $ctx.Common -Domain $ctx.Domain -Phase 'OU keyword group search' `
                    -LDAPFilter $filter -Properties $groupMetadataProps -SearchBase $ou.DistinguishedName `
                    -FailedGroupDomain $failedGroupDomain -Warnings $warnings
                [void](Add-GroupsFromSearch -Groups $groups -Seen $candidateSeen -List $candidateDns)
            }
        }

        if ($descriptionUserTokens.Count -gt 0) {
            Write-Host "    description user-token searches..."
            $tokenClauses = New-Object System.Collections.Generic.List[string]
            foreach ($token in $descriptionUserTokens) {
                $tokenClauses.Add((New-ContainsFilter -Attribute 'description' -Value $token))
                $tokenClauses.Add((New-ContainsFilter -Attribute 'info' -Value $token))
            }
            foreach ($batch in @(Get-Batches -Items $tokenClauses.ToArray() -BatchSize $ldapBatchSize)) {
                $filter = New-GroupSearchFilter -Clause (New-LdapOrFilter -Clauses $batch)
                $groups = Invoke-AdGroupSearch -Common $ctx.Common -Domain $ctx.Domain -Phase 'description user-token search' `
                    -LDAPFilter $filter -Properties $groupMetadataProps -FailedGroupDomain $failedGroupDomain -Warnings $warnings
                [void](Add-GroupsFromSearch -Groups $groups -Seen $candidateSeen -List $candidateDns)
            }
        }

        Write-Host "    known group lookups..."
        foreach ($known in @($InputData.KnownGroups)) {
            if ("$($known.Domain)" -ine "$($ctx.Domain)") { continue }
            $identity = "$($known.Identity)"
            if ([string]::IsNullOrWhiteSpace($identity)) { continue }
            if ($identity -match '^(?i:CN=)') {
                [void](Add-CandidateDn -DistinguishedName $identity -Seen $candidateSeen -List $candidateDns)
            } else {
                $filter = New-GroupSearchFilter -Clause (New-ExactFilter -Attribute 'name' -Value $identity)
                $groups = Invoke-AdGroupSearch -Common $ctx.Common -Domain $ctx.Domain -Phase 'known group lookup' `
                    -LDAPFilter $filter -Properties $groupMetadataProps -FailedGroupDomain $failedGroupDomain -Warnings $warnings
                [void](Add-GroupsFromSearch -Groups $groups -Seen $candidateSeen -List $candidateDns)
            }
        }

        # Candidate names become trusted only after the candidate has been found by
        # an independent signal (or by a previously trusted name). Keep separate,
        # per-domain ledgers for DNs and names so no related lookup is repeated.
        Write-Host "    related group lookups..."
        $queriedChildren = @{}       # child DN -> parent-membership query issued
        $queriedGroupNames = @{}     # normalized group name -> description/info query issued
        $hydratedByDn = @{}
        for ($round = 0; $round -lt 25; $round++) {
            $changed = $false

            # Hydration supplies authoritative names for candidates introduced as
            # bare DNs (memberOf and DN-form known.csv entries), and is cached for
            # final result shaping.
            foreach ($dn in @($candidateDns)) {
                $dnKey = $dn.ToLower()
                if ($hydratedByDn.ContainsKey($dnKey)) { continue }
                $group = Get-AdGroupByIdentity -Common $ctx.Common -Domain $ctx.Domain -Identity $dn -Properties $groupProps -Warnings $warnings
                $hydratedByDn[$dnKey] = $group
            }

            $searchDns = @()
            foreach ($dn in @($candidateDns)) {
                $key = $dn.ToLower()
                if ($queriedChildren.ContainsKey($key)) { continue }
                $queriedChildren[$key] = $true
                $searchDns += $dn
            }
            if ($searchDns.Count -gt 0) {
                $parentClauses = @($searchDns | ForEach-Object { New-ExactFilter -Attribute 'member' -Value $_ })
                foreach ($batch in @(Get-Batches -Items $parentClauses -BatchSize $ldapBatchSize)) {
                    $filter = New-GroupSearchFilter -Clause (New-LdapOrFilter -Clauses $batch)
                    $groups = Invoke-AdGroupSearch -Common $ctx.Common -Domain $ctx.Domain -Phase 'nested parent group lookup' `
                        -LDAPFilter $filter -Properties $groupMetadataProps -FailedGroupDomain $failedGroupDomain -Warnings $warnings
                    if ((Add-GroupsFromSearch -Groups $groups -Seen $candidateSeen -List $candidateDns) -gt 0) { $changed = $true }
                }
            }

            $newTrustedNames = New-Object System.Collections.Generic.List[string]
            foreach ($group in @($hydratedByDn.Values)) {
                if (-not $group) { continue }
                $name = "$($group.Name)".Trim()
                if ([string]::IsNullOrWhiteSpace($name)) { continue }
                $nameKey = $name.ToLower()
                if ($queriedGroupNames.ContainsKey($nameKey)) { continue }
                # Mark before issuing the LDAP call. A failed lookup is not retried
                # later in this domain and cannot multiply queries across rounds.
                $queriedGroupNames[$nameKey] = $true
                # LDAP substring filters can't express word boundaries, so a short
                # name ("IT", "App") would over-fetch a huge swath of the domain.
                # Skip names under 4 chars; the engine word-boundary check remains
                # the authority on what actually counts as a match.
                if ($name.Length -lt 4) { continue }
                $newTrustedNames.Add($name)
            }
            if ($newTrustedNames.Count -gt 0) {
                $nameClauses = New-Object System.Collections.Generic.List[string]
                foreach ($name in $newTrustedNames) {
                    $nameClauses.Add((New-ContainsFilter -Attribute 'description' -Value $name))
                    $nameClauses.Add((New-ContainsFilter -Attribute 'info' -Value $name))
                }
                foreach ($batch in @(Get-Batches -Items $nameClauses.ToArray() -BatchSize $ldapBatchSize)) {
                    $filter = New-GroupSearchFilter -Clause (New-LdapOrFilter -Clauses $batch)
                    $groups = Invoke-AdGroupSearch -Common $ctx.Common -Domain $ctx.Domain -Phase 'description group-name search' `
                        -LDAPFilter $filter -Properties $groupMetadataProps -FailedGroupDomain $failedGroupDomain -Warnings $warnings
                    if ((Add-GroupsFromSearch -Groups $groups -Seen $candidateSeen -List $candidateDns) -gt 0) { $changed = $true }
                }
            }

            $hasUnhydrated = $false
            foreach ($dn in @($candidateDns)) {
                if (-not $hydratedByDn.ContainsKey($dn.ToLower())) { $hasUnhydrated = $true; break }
            }
            if (-not $changed -and -not $hasUnhydrated) { break }
        }

        Write-Host "    shaping $($candidateDns.Count) candidate groups..."
        $domainGroupCount = 0
        foreach ($dn in $candidateDns) {
            $group = $hydratedByDn[$dn.ToLower()]
            if (-not $hydratedByDn.ContainsKey($dn.ToLower())) {
                $group = Get-AdGroupByIdentity -Common $ctx.Common -Domain $ctx.Domain -Identity $dn -Properties $groupProps -Warnings $warnings
            }
            if (-not $group) { continue }
            $memberDirectoryObjects = New-Object System.Collections.Generic.List[object]
            foreach ($memberDn in @($group.member)) {
                $memberObject = Resolve-AdMemberObject -Common $ctx.Common -DistinguishedName $memberDn -Cache $memberObjectCache
                if ($memberObject) { $memberDirectoryObjects.Add($memberObject) }
            }
            $allGroups.Add([pscustomobject]@{
                Domain = $ctx.Domain; Name = $group.Name; DistinguishedName = $group.DistinguishedName
                Description = $group.description; Info = $group.info; ManagedBy = $group.managedBy
                Member = @($group.member); MemberOf = @($group.memberof)
                MemberDirectoryObjects = $memberDirectoryObjects.ToArray()
                GroupScope = "$($group.GroupScope)"; GroupCategory = "$($group.GroupCategory)"
                Mail = $group.mail; AdminCount = $group.adminCount
                WhenCreated = $group.whenCreated; WhenChanged = $group.whenChanged
            })
            $domainGroupCount++
        }
        if ($failedGroupDomain.ContainsKey($ctx.Domain) -and -not ($failedDomains -contains $ctx.Domain)) {
            $failedDomains.Add($ctx.Domain)
        }
        Write-Host "  [$($ctx.Index)/$domainTotal] $($ctx.Domain) - $domainGroupCount candidate groups, $($domainUserCounts[$ctx.Domain]) vendor users"
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
