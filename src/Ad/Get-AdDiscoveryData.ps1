function Get-AdDiscoveryData {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$InputData,
        [System.Management.Automation.PSCredential]$Credential,
        [hashtable]$DomainCredentials,
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

    function Get-OptionalPropertyValue {
        param([object]$InputObject, [Parameter(Mandatory)][string]$Name)
        if (-not $InputObject) { return $null }
        $property = $InputObject.PSObject.Properties[$Name]
        if (-not $property) { return $null }
        return $property.Value
    }

    function Get-CredentialFromMap {
        param([hashtable]$CredentialMap, [Parameter(Mandatory)][string]$Domain)
        if (-not $CredentialMap) { return $null }

        $value = $null
        $found = $false
        if ($CredentialMap.ContainsKey($Domain)) {
            $value = $CredentialMap[$Domain]
            $found = $true
        } else {
            foreach ($key in @($CredentialMap.Keys)) {
                if ("$key" -ieq $Domain) {
                    $value = $CredentialMap[$key]
                    $found = $true
                    break
                }
            }
        }

        if (-not $found -or -not $value) { return $null }
        if ($value -isnot [System.Management.Automation.PSCredential]) {
            throw "DomainCredentials entry for '$Domain' must be a PSCredential."
        }
        return $value
    }

    function Get-DomainCredential {
        param(
            [Parameter(Mandatory)][object]$DomainRow,
            [System.Management.Automation.PSCredential]$DefaultCredential,
            [hashtable]$CredentialMap,
            [Parameter(Mandatory)][hashtable]$PromptedCredentials
        )

        $domain = "$($DomainRow.Domain)"
        $mappedCredential = Get-CredentialFromMap -CredentialMap $CredentialMap -Domain $domain
        if ($mappedCredential) { return $mappedCredential }

        $credentialUser = "$(Get-OptionalPropertyValue -InputObject $DomainRow -Name 'CredentialUser')".Trim()
        if ([string]::IsNullOrWhiteSpace($credentialUser)) { return $DefaultCredential }

        $cacheKey = $credentialUser.ToLowerInvariant()
        if (-not $PromptedCredentials.ContainsKey($cacheKey)) {
            $promptedCredential = Get-Credential -UserName $credentialUser -Message "Credential for AD discovery in $domain"
            if (-not $promptedCredential) {
                throw "Credential prompt was cancelled for '$domain' ($credentialUser)."
            }
            $PromptedCredentials[$cacheKey] = $promptedCredential
        }
        return $PromptedCredentials[$cacheKey]
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
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $found = @(Get-ADGroup @query)
            $queryStats['GroupSearches']++
            Write-DiscoveryLog -Level DEBUG -Message ("[{0}] group search ({1}): {2} result(s) in {3} ms, filter {4} chars{5}" -f `
                $Domain, $Phase, $found.Count, $sw.ElapsedMilliseconds, $LDAPFilter.Length, `
                $(if ($SearchBase) { ", base $SearchBase" } else { '' }))
            foreach ($g in $found) {
                if (-not $g) { continue }
                Add-CachedMemberObject -Cache $memberObjectCache -DistinguishedName "$($g.DistinguishedName)" `
                    -SamAccountName "$($g.SamAccountName)" -DisplayName "$($g.DisplayName)" -Name "$($g.Name)" -ObjectClass 'group'
            }
            return $found
        } catch {
            $FailedGroupDomain[$Domain] = $true
            $Warnings.Add("Group lookup failed in '$Domain' during $Phase`: $($_.Exception.Message)")
            Write-DiscoveryLog -Level WARN -Message ("[{0}] group search ({1}) failed: {2}" -f $Domain, $Phase, $_.Exception.Message)
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
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $found = @(Get-ADOrganizationalUnit @query)
            $queryStats['OuSearches']++
            Write-DiscoveryLog -Level DEBUG -Message ("[{0}] OU search: {1} result(s) in {2} ms" -f $Domain, $found.Count, $sw.ElapsedMilliseconds)
            return $found
        } catch {
            $FailedGroupDomain[$Domain] = $true
            $Warnings.Add("OU lookup failed in '$Domain': $($_.Exception.Message)")
            Write-DiscoveryLog -Level WARN -Message ("[{0}] OU search failed: {1}" -f $Domain, $_.Exception.Message)
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
            $queryStats['IdentityFetches']++
            if ($group) {
                Add-CachedMemberObject -Cache $memberObjectCache -DistinguishedName "$($group.DistinguishedName)" `
                    -SamAccountName "$($group.SamAccountName)" -DisplayName "$($group.DisplayName)" -Name "$($group.Name)" -ObjectClass 'group'
            }
            if ($SecurityGroupsOnly -and $group -and "$($group.GroupCategory)" -and "$($group.GroupCategory)" -ne 'Security') {
                return $null
            }
            return $group
        } catch {
            $Warnings.Add("Group lookup failed in '$Domain' for '$Identity': $($_.Exception.Message)")
            Write-DiscoveryLog -Level WARN -Message ("[{0}] identity fetch failed for '{1}': {2}" -f $Domain, $Identity, $_.Exception.Message)
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
            [Parameter(Mandatory)]$List,
            [hashtable]$ObjectCache
        )
        $count = 0
        foreach ($group in @($Groups)) {
            if ($group -and $null -ne $ObjectCache) {
                # Keep the full search-returned object so hydration can reuse it
                # instead of re-fetching the same group by identity.
                $dn = "$($group.DistinguishedName)"
                if (-not [string]::IsNullOrWhiteSpace($dn)) {
                    $dnKey = $dn.ToLower()
                    if (-not $ObjectCache.ContainsKey($dnKey)) { $ObjectCache[$dnKey] = $group }
                }
            }
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
        if ($Cache.ContainsKey($key)) { $queryStats['MemberCacheHits']++; return $Cache[$key] }

        $query = @{} + $Common
        $query['Identity'] = $DistinguishedName
        $query['Properties'] = $memberObjectProps
        $queryStats['MemberFetches']++
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

    function Add-CachedMemberObject {
        # Pre-seed the member-object cache from an object an earlier AD query
        # already returned (or one synthesized loss-free, as with FSP DNs built
        # from a known SID), so report shaping never re-fetches it via
        # Get-ADObject. First write wins; entries mirror the shape
        # Resolve-AdMemberObject builds.
        param(
            [Parameter(Mandatory)][hashtable]$Cache,
            [string]$DistinguishedName,
            [string]$SamAccountName,
            [string]$DisplayName,
            [string]$Name,
            [string]$ObjectClass
        )
        if ([string]::IsNullOrWhiteSpace($DistinguishedName)) { return }
        $key = $DistinguishedName.ToLower()
        if ($Cache.ContainsKey($key)) { return }
        $Cache[$key] = [pscustomobject]@{
            DistinguishedName = $DistinguishedName
            SamAccountName    = "$SamAccountName"
            DisplayName       = "$DisplayName"
            Name              = "$Name"
            ObjectClass       = "$ObjectClass"
        }
    }

    function ConvertTo-EngineGroup {
        # Shape a hydrated raw AD group into the object Find-CandidateGroups
        # expects, minus member hydration (scoring only needs the Member DN
        # list; MemberDirectoryObjects are display-only and cost one
        # Get-ADObject per member, so they are resolved only at final shaping).
        param([Parameter(Mandatory)][object]$Group, [Parameter(Mandatory)][string]$Domain)
        [pscustomobject]@{
            Domain = $Domain; Name = $Group.Name; DistinguishedName = $Group.DistinguishedName
            Description = $Group.description; Info = $Group.info; ManagedBy = $Group.managedBy
            Member = @($Group.member); MemberOf = @($Group.memberof)
            MemberDirectoryObjects = @()
            GroupScope = "$($Group.GroupScope)"; GroupCategory = "$($Group.GroupCategory)"
            Mail = $Group.mail; AdminCount = $Group.adminCount
            WhenCreated = $Group.whenCreated; WhenChanged = $Group.whenChanged
        }
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
    # LDAP round-trip ledger; nested helpers increment it in place so the log can
    # report exactly how much directory work a run cost.
    $queryStats = @{ GroupSearches = 0; OuSearches = 0; UserSearches = 0
                     IdentityFetches = 0; MemberFetches = 0; MemberCacheHits = 0 }
    $adTimer = [System.Diagnostics.Stopwatch]::StartNew()
    Write-DiscoveryLog ("AD acquisition: {0} domain(s), {1} CSV user(s), {2} keyword(s), {3} known group(s); sam batch {4}, ldap batch {5}" -f `
        @($InputData.Domains).Count, @($InputData.Users).Count, @($InputData.Keywords).Count, `
        @($InputData.KnownGroups).Count, $samBatchSize, $ldapBatchSize)
    $sidSeen       = @{}   # objectSid string -> already resolved (dedupe same physical user across domains)
    $failedGroupDomain = @{}
    $memberObjectCache = @{}
    $promptedDomainCredentials = @{}

    # Validate CSV users once and index them by sam so batched query results can be
    # mapped back to their CSV row for token building.
    $csvUserBySam = @{}   # PowerShell hashtable: string keys are case-insensitive
    foreach ($csvUser in $InputData.Users) {
        $sam = $csvUser.SamAccountName
        if ([string]::IsNullOrWhiteSpace($sam)) { continue }
        if ($sam -match "['()*\\/]") {
            $warnings.Add("Skipping user with suspicious SamAccountName '$sam'")
            Write-DiscoveryLog -Level WARN -Message "Skipping user with suspicious SamAccountName '$sam'"
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
        $domainCredential = Get-DomainCredential -DomainRow $d -DefaultCredential $Credential `
            -CredentialMap $DomainCredentials -PromptedCredentials $promptedDomainCredentials
        if ($domainCredential) { $common['Credential'] = $domainCredential }
        $domainContexts.Add([pscustomobject]@{
            Index    = $domainIndex
            Domain   = $d.Domain
            Server   = $server
            DomainDn = ConvertTo-DomainDistinguishedName -Domain $d.Domain
            Common   = $common
        })

        Write-Host "  [$domainIndex/$domainTotal] $($d.Domain) via $server - resolving vendor users..."
        $userTimer = [System.Diagnostics.Stopwatch]::StartNew()
        $domainUserCount = 0
        for ($i = 0; $i -lt $validSams.Count; $i += $samBatchSize) {
            $last = [Math]::Min($i + $samBatchSize, $validSams.Count) - 1
            $batchFilter = New-SamLdapFilter -SamAccountNames $validSams[$i..$last]
            try {
                $sw = [System.Diagnostics.Stopwatch]::StartNew()
                $found = @(Get-ADUser @common -LDAPFilter $batchFilter -Properties $userProps)
                $queryStats['UserSearches']++
                Write-DiscoveryLog -Level DEBUG -Message ("[{0}] user search: sams {1}-{2} of {3} returned {4} object(s) in {5} ms" -f `
                    $d.Domain, ($i + 1), ($last + 1), $validSams.Count, $found.Count, $sw.ElapsedMilliseconds)
            } catch {
                $warnings.Add("User lookup failed in '$($d.Domain)': $($_.Exception.Message)")
                Write-DiscoveryLog -Level WARN -Message ("[{0}] user search failed: {1}" -f $d.Domain, $_.Exception.Message)
                continue
            }
            foreach ($u in $found) {
                if (-not $u) { continue }
                # Cache every returned user (even ones skipped below) so report
                # shaping never re-fetches them via Get-ADObject.
                Add-CachedMemberObject -Cache $memberObjectCache -DistinguishedName "$($u.DistinguishedName)" `
                    -SamAccountName "$($u.SamAccountName)" -DisplayName "$($u.displayName)" -Name "$($u.Name)" -ObjectClass 'user'
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
        Write-DiscoveryLog ("[{0}] resolved {1} vendor user(s) in {2} ms" -f $d.Domain, $domainUserCount, $userTimer.ElapsedMilliseconds)
    }

    $allVendorUsers = $vendorUsers.ToArray()
    $keywords = @($InputData.Keywords | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $descriptionUserTokens = @($allVendorUsers | ForEach-Object { $_.Tokens } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)

    # Inputs for the in-memory engine pass that gates trusted-name searches
    # (built once; same construction as Invoke-DiscoveryEngine).
    $knownKeys = @{}
    foreach ($k in $InputData.KnownGroups)   { $knownKeys[(Get-GroupLookupKey -Domain $k.Domain -Identity $k.Identity)] = $true }
    $excludeKeys = @{}
    foreach ($e in $InputData.ExcludeGroups) { $excludeKeys[(Get-GroupLookupKey -Domain $e.Domain -Identity $e.Identity)] = $true }
    $confidenceRank = Get-ConfidenceRank

    foreach ($ctx in $domainContexts) {
        Write-Host "  [$($ctx.Index)/$domainTotal] $($ctx.Domain) - finding candidate groups..."
        $domainTimer = [System.Diagnostics.Stopwatch]::StartNew()
        $candidateSeen = @{}
        $candidateDns = New-Object System.Collections.Generic.List[string]
        $fetchedGroupByDn = @{}   # dn -> full search-returned object, reused at hydration

        Write-Host "    direct vendor memberships..."
        $phaseMark = $candidateDns.Count
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
                # An FSP object carries nothing beyond its SID (name = SID, no
                # sam/displayName), so this synthesized entry is loss-free and
                # saves one Get-ADObject per vendor FSP membership. If the FSP
                # does not exist in this domain, no member list references it
                # and the entry is simply never consulted.
                Add-CachedMemberObject -Cache $memberObjectCache -DistinguishedName $fspDn `
                    -SamAccountName '' -DisplayName '' -Name "$($u.Sid)" -ObjectClass 'foreignSecurityPrincipal'
                $memberClauses.Add((New-ExactFilter -Attribute 'member' -Value $fspDn))
            }
        }
        foreach ($batch in @(Get-Batches -Items $memberClauses.ToArray() -BatchSize $ldapBatchSize)) {
            $filter = New-GroupSearchFilter -Clause (New-LdapOrFilter -Clauses $batch)
            $groups = Invoke-AdGroupSearch -Common $ctx.Common -Domain $ctx.Domain -Phase 'direct vendor membership' `
                -LDAPFilter $filter -Properties $groupProps -FailedGroupDomain $failedGroupDomain -Warnings $warnings
            [void](Add-GroupsFromSearch -Groups $groups -Seen $candidateSeen -List $candidateDns -ObjectCache $fetchedGroupByDn)
        }
        Write-DiscoveryLog ("[{0}] direct vendor memberships: +{1} candidate(s) ({2} total)" -f `
            $ctx.Domain, ($candidateDns.Count - $phaseMark), $candidateDns.Count)

        if ($keywords.Count -gt 0) {
            Write-Host "    keyword searches..."
            $phaseMark = $candidateDns.Count
            $keywordClauses = New-Object System.Collections.Generic.List[string]
            foreach ($keyword in $keywords) {
                $keywordClauses.Add((New-ContainsFilter -Attribute 'name' -Value $keyword))
                $keywordClauses.Add((New-ContainsFilter -Attribute 'description' -Value $keyword))
                $keywordClauses.Add((New-ContainsFilter -Attribute 'info' -Value $keyword))
            }
            foreach ($batch in @(Get-Batches -Items $keywordClauses.ToArray() -BatchSize $ldapBatchSize)) {
                $filter = New-GroupSearchFilter -Clause (New-LdapOrFilter -Clauses $batch)
                $groups = Invoke-AdGroupSearch -Common $ctx.Common -Domain $ctx.Domain -Phase 'keyword search' `
                    -LDAPFilter $filter -Properties $groupProps -FailedGroupDomain $failedGroupDomain -Warnings $warnings
                [void](Add-GroupsFromSearch -Groups $groups -Seen $candidateSeen -List $candidateDns -ObjectCache $fetchedGroupByDn)
            }

            Write-DiscoveryLog ("[{0}] keyword searches: +{1} candidate(s) ({2} total)" -f `
                $ctx.Domain, ($candidateDns.Count - $phaseMark), $candidateDns.Count)

            Write-Host "    OU keyword searches..."
            $phaseMark = $candidateDns.Count
            $ouClauses = @($keywords | ForEach-Object { New-ContainsFilter -Attribute 'name' -Value $_ })
            $ouFilter = New-LdapOrFilter -Clauses $ouClauses
            $ous = Invoke-AdOuSearch -Common $ctx.Common -Domain $ctx.Domain -LDAPFilter $ouFilter `
                -FailedGroupDomain $failedGroupDomain -Warnings $warnings
            foreach ($ou in @($ous)) {
                if ([string]::IsNullOrWhiteSpace($ou.DistinguishedName)) { continue }
                $filter = New-GroupSearchFilter -Clause '(objectClass=group)'
                $groups = Invoke-AdGroupSearch -Common $ctx.Common -Domain $ctx.Domain -Phase 'OU keyword group search' `
                    -LDAPFilter $filter -Properties $groupProps -SearchBase $ou.DistinguishedName `
                    -FailedGroupDomain $failedGroupDomain -Warnings $warnings
                [void](Add-GroupsFromSearch -Groups $groups -Seen $candidateSeen -List $candidateDns -ObjectCache $fetchedGroupByDn)
            }
            Write-DiscoveryLog ("[{0}] OU keyword searches: {1} matching OU(s), +{2} candidate(s) ({3} total)" -f `
                $ctx.Domain, @($ous).Count, ($candidateDns.Count - $phaseMark), $candidateDns.Count)
        }

        if ($descriptionUserTokens.Count -gt 0) {
            Write-Host "    description user-token searches..."
            $phaseMark = $candidateDns.Count
            $tokenClauses = New-Object System.Collections.Generic.List[string]
            foreach ($token in $descriptionUserTokens) {
                $tokenClauses.Add((New-ContainsFilter -Attribute 'description' -Value $token))
                $tokenClauses.Add((New-ContainsFilter -Attribute 'info' -Value $token))
            }
            foreach ($batch in @(Get-Batches -Items $tokenClauses.ToArray() -BatchSize $ldapBatchSize)) {
                $filter = New-GroupSearchFilter -Clause (New-LdapOrFilter -Clauses $batch)
                $groups = Invoke-AdGroupSearch -Common $ctx.Common -Domain $ctx.Domain -Phase 'description user-token search' `
                    -LDAPFilter $filter -Properties $groupProps -FailedGroupDomain $failedGroupDomain -Warnings $warnings
                [void](Add-GroupsFromSearch -Groups $groups -Seen $candidateSeen -List $candidateDns -ObjectCache $fetchedGroupByDn)
            }
            Write-DiscoveryLog ("[{0}] description user-token searches ({1} token(s)): +{2} candidate(s) ({3} total)" -f `
                $ctx.Domain, $descriptionUserTokens.Count, ($candidateDns.Count - $phaseMark), $candidateDns.Count)
        }

        Write-Host "    known group lookups..."
        $phaseMark = $candidateDns.Count
        foreach ($known in @($InputData.KnownGroups)) {
            if ("$($known.Domain)" -ine "$($ctx.Domain)") { continue }
            $identity = "$($known.Identity)"
            if ([string]::IsNullOrWhiteSpace($identity)) { continue }
            if ($identity -match '^(?i:CN=)') {
                [void](Add-CandidateDn -DistinguishedName $identity -Seen $candidateSeen -List $candidateDns)
            } else {
                $filter = New-GroupSearchFilter -Clause (New-ExactFilter -Attribute 'name' -Value $identity)
                $groups = Invoke-AdGroupSearch -Common $ctx.Common -Domain $ctx.Domain -Phase 'known group lookup' `
                    -LDAPFilter $filter -Properties $groupProps -FailedGroupDomain $failedGroupDomain -Warnings $warnings
                [void](Add-GroupsFromSearch -Groups $groups -Seen $candidateSeen -List $candidateDns -ObjectCache $fetchedGroupByDn)
            }
        }
        Write-DiscoveryLog ("[{0}] known group lookups: +{1} candidate(s) ({2} total)" -f `
            $ctx.Domain, ($candidateDns.Count - $phaseMark), $candidateDns.Count)

        # Candidate names feed description searches only when the engine itself
        # would trust them: each round runs the real matching pipeline over the
        # hydrated candidates and keeps names passing Test-TrustedNameSource
        # (the same predicate Expand-VendorGroupClosure uses). Trust is
        # recomputed every round as candidates arrive, so transitive chains
        # still expand one LDAP hop per round. Keep separate, per-domain
        # ledgers for DNs and names so no related lookup is repeated.
        Write-Host "    related group lookups..."
        $queriedChildren = @{}       # child DN -> parent-membership query issued
        $queriedGroupNames = @{}     # normalized group name -> description/info query issued
        $hydratedByDn = @{}
        $roundsRun = 0
        for ($round = 0; $round -lt 25; $round++) {
            $roundsRun = $round + 1
            $hydratedMark = $hydratedByDn.Count
            $changed = $false

            # Hydration supplies authoritative attributes for every candidate and
            # is cached for final result shaping. Candidates that arrived as full
            # search results are reused as-is; only candidates introduced as bare
            # DNs (memberOf and DN-form known.csv entries) cost an identity fetch.
            foreach ($dn in @($candidateDns)) {
                $dnKey = $dn.ToLower()
                if ($hydratedByDn.ContainsKey($dnKey)) { continue }
                $group = $null
                if ($fetchedGroupByDn.ContainsKey($dnKey)) {
                    $fetched = $fetchedGroupByDn[$dnKey]
                    # Reuse only when the search actually carried the heavy
                    # attributes; a result without them still hydrates normally.
                    if ($fetched.PSObject.Properties['member'] -and $fetched.PSObject.Properties['memberOf']) {
                        $group = $fetched
                    }
                }
                if (-not $group) {
                    $group = Get-AdGroupByIdentity -Common $ctx.Common -Domain $ctx.Domain -Identity $dn -Properties $groupProps -Warnings $warnings
                }
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
                        -LDAPFilter $filter -Properties $groupProps -FailedGroupDomain $failedGroupDomain -Warnings $warnings
                    if ((Add-GroupsFromSearch -Groups $groups -Seen $candidateSeen -List $candidateDns -ObjectCache $fetchedGroupByDn) -gt 0) { $changed = $true }
                }
            }

            # Ask the engine which names it would trust. Pure in-memory work
            # over at most a few hundred candidates -- negligible next to the
            # LDAP fetches it prevents (each untrusted-name search costs the
            # search itself plus per-group hydration and per-member resolution
            # for every junk group it returns).
            $trustedNameSet = @{}
            $engineGroups = @(
                foreach ($group in $hydratedByDn.Values) {
                    if ($group) { ConvertTo-EngineGroup -Group $group -Domain $ctx.Domain }
                }
            )
            if ($engineGroups.Count -gt 0) {
                $engineResults = Find-CandidateGroups -Groups $engineGroups -Keywords $keywords `
                    -VendorUsers $allVendorUsers -KnownKeys $knownKeys -ExcludeKeys $excludeKeys
                $engineResults = Expand-VendorGroupClosure -Results $engineResults
                foreach ($res in @($engineResults)) {
                    if (Test-TrustedNameSource -Result $res -Rank $confidenceRank) {
                        $trustedNameSet[("$($res.Name)".Trim().ToLower())] = $true
                    }
                }
            }

            $newTrustedNames = New-Object System.Collections.Generic.List[string]
            foreach ($group in @($hydratedByDn.Values)) {
                if (-not $group) { continue }
                $name = "$($group.Name)".Trim()
                if ([string]::IsNullOrWhiteSpace($name)) { continue }
                $nameKey = $name.ToLower()
                if ($queriedGroupNames.ContainsKey($nameKey)) { continue }
                # An untrusted name stays unmarked: a later round can still make
                # it trusted (e.g. a transitive description mention) and it must
                # remain searchable then.
                if (-not $trustedNameSet.ContainsKey($nameKey)) { continue }
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
                        -LDAPFilter $filter -Properties $groupProps -FailedGroupDomain $failedGroupDomain -Warnings $warnings
                    if ((Add-GroupsFromSearch -Groups $groups -Seen $candidateSeen -List $candidateDns -ObjectCache $fetchedGroupByDn) -gt 0) { $changed = $true }
                }
            }

            Write-DiscoveryLog -Level DEBUG -Message ("[{0}] related round {1}: hydrated +{2}, parent lookups for {3} DN(s), {4} trusted name(s) searched, {5} candidate(s) total" -f `
                $ctx.Domain, $roundsRun, ($hydratedByDn.Count - $hydratedMark), $searchDns.Count, $newTrustedNames.Count, $candidateDns.Count)

            $hasUnhydrated = $false
            foreach ($dn in @($candidateDns)) {
                if (-not $hydratedByDn.ContainsKey($dn.ToLower())) { $hasUnhydrated = $true; break }
            }
            if (-not $changed -and -not $hasUnhydrated) { break }
        }
        Write-DiscoveryLog ("[{0}] related group lookups converged after {1} round(s): {2} candidate(s)" -f `
            $ctx.Domain, $roundsRun, $candidateDns.Count)

        Write-Host "    shaping $($candidateDns.Count) candidate groups..."
        $shapeTimer = [System.Diagnostics.Stopwatch]::StartNew()
        $memberFetchMark = $queryStats['MemberFetches']
        $memberHitMark   = $queryStats['MemberCacheHits']
        $memberRefCount  = 0
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
                if ($memberObject) { $memberDirectoryObjects.Add($memberObject); $memberRefCount++ }
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
        Write-DiscoveryLog ("[{0}] shaped {1} group(s) with {2} member reference(s) ({3} directory fetches, {4} cache hits) in {5} ms" -f `
            $ctx.Domain, $domainGroupCount, $memberRefCount, `
            ($queryStats['MemberFetches'] - $memberFetchMark), ($queryStats['MemberCacheHits'] - $memberHitMark), $shapeTimer.ElapsedMilliseconds)
        if ($failedGroupDomain.ContainsKey($ctx.Domain) -and -not ($failedDomains -contains $ctx.Domain)) {
            $failedDomains.Add($ctx.Domain)
        }
        Write-Host "  [$($ctx.Index)/$domainTotal] $($ctx.Domain) - $domainGroupCount candidate groups, $($domainUserCounts[$ctx.Domain]) vendor users"
        Write-DiscoveryLog ("[{0}] domain complete in {1:n1} s: {2} candidate group(s), {3} vendor user(s)" -f `
            $ctx.Domain, $domainTimer.Elapsed.TotalSeconds, $domainGroupCount, $domainUserCounts[$ctx.Domain])
    }

    $groupsArr = $allGroups.ToArray()
    $usersArr  = $vendorUsers.ToArray()
    Write-DiscoveryLog ("AD acquisition complete in {0:n1} s: {1} group(s), {2} vendor user(s), {3} warning(s), {4} failed domain(s)" -f `
        $adTimer.Elapsed.TotalSeconds, $groupsArr.Count, $usersArr.Count, $warnings.Count, $failedDomains.Count)
    Write-DiscoveryLog ("LDAP work: {0} group searches, {1} OU searches, {2} user searches, {3} identity fetches, {4} member fetches ({5} member cache hits)" -f `
        $queryStats['GroupSearches'], $queryStats['OuSearches'], $queryStats['UserSearches'], `
        $queryStats['IdentityFetches'], $queryStats['MemberFetches'], $queryStats['MemberCacheHits'])
    [pscustomobject]@{
        Groups        = $groupsArr
        VendorUsers   = $usersArr
        DnIndex       = (Resolve-DirectoryIndex -VendorUsers $usersArr -Groups $groupsArr)
        FailedDomains = $failedDomains.ToArray()
        Warnings      = $warnings.ToArray()
    }
}
