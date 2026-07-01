function Get-VendorUserMemberships {
    # Pure projection: one normalized row per (vendor user, group) membership.
    # Combined source so cross-domain memberships are not lost:
    #   (b) discovered groups whose member list resolves to the vendor user (via
    #       real DN or foreign-security-principal SID) -> authoritative Domain/Name,
    #       the only source that sees cross-domain memberships;
    #   (a) the user's memberOf -> all home-domain groups, Domain/Name parsed from DN.
    # Discovered rows win on dedup (authoritative name over DN-derived).
    [CmdletBinding()]
    param([object[]]$VendorUsers, [object[]]$Groups)

    function Get-UserKey {
        param([object]$User)
        if ($User.Sid)               { return 'sid:' + ([string]$User.Sid).ToLower() }
        if ($User.DistinguishedName) { return 'dn:'  + $User.DistinguishedName.ToLower() }
        return 'sam:' + ([string]$User.SamAccountName).ToLower()
    }

    $index = New-VendorPrincipalIndex -VendorUsers $VendorUsers

    # Pre-index discovered groups by the vendor user found in their member list.
    $discoveredByUser = @{}
    foreach ($g in @($Groups)) {
        foreach ($memberDn in @($g.Member)) {
            $matchUser = Resolve-VendorPrincipal -Identity $memberDn -Index $index
            if (-not $matchUser) { continue }
            $key = Get-UserKey -User $matchUser
            if (-not $discoveredByUser.ContainsKey($key)) {
                $discoveredByUser[$key] = New-Object System.Collections.Generic.List[object]
            }
            $discoveredByUser[$key].Add($g)
        }
    }

    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($user in @($VendorUsers)) {
        $seen = @{}   # lowercased group DN -> already emitted for this user
        $userKey = Get-UserKey -User $user

        if ($discoveredByUser.ContainsKey($userKey)) {
            foreach ($g in $discoveredByUser[$userKey]) {
                $dnKey = ([string]$g.DistinguishedName).ToLower()
                if ($seen.ContainsKey($dnKey)) { continue }
                $seen[$dnKey] = $true
                $rows.Add([pscustomobject]@{
                    UserDomain         = $user.Domain
                    UserSamAccountName = $user.SamAccountName
                    UserDisplayName    = $user.DisplayName
                    GroupDomain        = $g.Domain
                    GroupName          = $g.Name
                })
            }
        }

        foreach ($dn in @($user.MemberOf)) {
            if ([string]::IsNullOrWhiteSpace($dn)) { continue }
            $dnKey = $dn.ToLower()
            if ($seen.ContainsKey($dnKey)) { continue }
            $seen[$dnKey] = $true
            $parsed = Get-DnDomainAndName -DistinguishedName $dn
            $rows.Add([pscustomobject]@{
                UserDomain         = $user.Domain
                UserSamAccountName = $user.SamAccountName
                UserDisplayName    = $user.DisplayName
                GroupDomain        = $parsed.Domain
                GroupName          = $parsed.Name
            })
        }
    }

    $rows | Sort-Object UserSamAccountName, GroupDomain, GroupName
}
