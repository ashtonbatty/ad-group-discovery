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

        $reasons = @()
        $reasons += Get-NameMatchReason       -GroupName $g.Name -Keywords $Keywords
        $reasons += Get-ContainerMatchReason  -DistinguishedName $g.DistinguishedName -Keywords $Keywords
        $reasons += Get-DescriptionMatchReasons -Description $g.Description -Info $g.Info -Keywords $Keywords -VendorUsers $VendorUsers
        $reasons += Get-OwnerMatchReason      -ManagedBy $g.ManagedBy -VendorUsers $VendorUsers -Index $vendorIndex
        $reasons += Get-MemberMatchReasons    -Member $g.Member -VendorUsers $VendorUsers -Index $vendorIndex
        $reasons = @($reasons | Where-Object { $_ })

        $cc = Get-MatchConfidence -Reasons $reasons -IsKnown:$isKnown
        $source = if ($isKnown) { 'Known' } else { 'Discovered' }

        $results.Add([pscustomobject]@{
            Domain = $g.Domain; Name = $g.Name; DistinguishedName = $g.DistinguishedName
            Description = $g.Description; Info = $g.Info; ManagedBy = $g.ManagedBy
            Member = @($g.Member); MemberOf = @($g.MemberOf)
            GroupScope = $g.GroupScope; GroupCategory = $g.GroupCategory; Mail = $g.Mail
            AdminCount = $g.AdminCount; WhenCreated = $g.WhenCreated; WhenChanged = $g.WhenChanged
            Reasons = $reasons; Score = $cc.Score; Confidence = $cc.Confidence
            IsKnown = $isKnown; Source = $source
        })
    }
    if ($results.Count) { return ,$results.ToArray() }
    return @()
}
