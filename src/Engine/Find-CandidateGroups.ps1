function Find-CandidateGroups {
    [CmdletBinding()]
    param(
        [object[]]$Groups, [string[]]$Keywords, [object[]]$VendorUsers,
        [hashtable]$KnownKeys, [hashtable]$ExcludeKeys
    )
    $vendorIndex = New-VendorPrincipalIndex -VendorUsers $VendorUsers
    $results = New-Object System.Collections.Generic.List[object]
    foreach ($g in $Groups) {
        $dnKey   = Get-GroupLookupKey -Domain $g.Domain -Identity $g.DistinguishedName
        $nameKey = Get-GroupLookupKey -Domain $g.Domain -Identity $g.Name
        if ($ExcludeKeys.ContainsKey($dnKey) -or $ExcludeKeys.ContainsKey($nameKey)) { continue }
        $isKnown = $KnownKeys.ContainsKey($dnKey) -or $KnownKeys.ContainsKey($nameKey)

        $reasons = @(@(
            Get-NameMatchReason       -GroupName $g.Name -Keywords $Keywords
            Get-ContainerMatchReason  -DistinguishedName $g.DistinguishedName -Keywords $Keywords
            Get-DescriptionMatchReasons -Description $g.Description -Info $g.Info -Keywords $Keywords -VendorUsers $VendorUsers
            Get-OwnerMatchReason      -ManagedBy $g.ManagedBy -VendorUsers $VendorUsers -Index $vendorIndex
            Get-MemberMatchReasons    -Member $g.Member -VendorUsers $VendorUsers -Index $vendorIndex
        ) | Where-Object { $_ })

        $cc = Get-MatchConfidence -Reasons $reasons -IsKnown:$isKnown
        $source = if ($isKnown) { 'Known' } else { 'Discovered' }

        # A group is vendor-dedicated when every member resolves to a vendor user
        # (each resolvable member yields exactly one MemberVendorUser reason).
        # Expand-VendorGroupClosure uses this to decide whether a member-only
        # match may seed description-name trust.
        $memberDns = @(@($g.Member) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $vendorMemberCount = @($reasons | Where-Object { $_.Pattern -eq 'MemberVendorUser' }).Count
        $allMembersVendor = ($memberDns.Count -gt 0 -and $vendorMemberCount -eq $memberDns.Count)

        $results.Add([pscustomobject]@{
            Domain = $g.Domain; Name = $g.Name; DistinguishedName = $g.DistinguishedName
            Description = $g.Description; Info = $g.Info; ManagedBy = $g.ManagedBy
            Member = @($g.Member); MemberOf = @($g.MemberOf)
            MemberDirectoryObjects = @($g.MemberDirectoryObjects)
            GroupScope = $g.GroupScope; GroupCategory = $g.GroupCategory; Mail = $g.Mail
            AdminCount = $g.AdminCount; WhenCreated = $g.WhenCreated; WhenChanged = $g.WhenChanged
            Reasons = $reasons; Score = $cc.Score; Confidence = $cc.Confidence
            AllMembersVendor = $allMembersVendor
            IsKnown = $isKnown; Source = $source
        })
    }
    # ,@() would emit a single empty-array item (Count 1) downstream; the guard keeps
    # the empty case emitting nothing.
    if ($results.Count) { return ,$results.ToArray() }
    return @()
}
