function Test-TrustedNameSource {
    # Single authority on whether a result's name may seed description-name
    # trust. Used by Expand-VendorGroupClosure (to add DescriptionGroup reasons)
    # and by Get-AdDiscoveryData (to decide which names are worth LDAP
    # description searches), so the fetch layer can never trust more or less
    # than the engine does.
    #
    # Vendor membership and nested vendor containment alone are not independent
    # evidence: a vendor account sitting in a shared or built-in group
    # ("Domain Admins") must not turn that group's name into a trusted token,
    # and a vendor-owned child inside built-in "Administrators" must not turn
    # the parent's generic name into a trusted token either. Member-only groups
    # still qualify when the membership is exclusively vendor users
    # (vendor-dedicated) or the group is listed in known.csv.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Result,
        [Parameter(Mandatory)][hashtable]$Rank
    )
    if ($Result.IsKnown) { return $true }
    if ($Rank[$Result.Confidence] -lt $Rank['Low']) { return $false }
    # Independent evidence = a signal about THIS group's own identity (name,
    # container, owner, description). Vendor membership is not (a vendor account
    # in "Domain Admins" must not trust that name) and neither is nested vendor
    # containment (a vendor-owned child inside built-in "Administrators" must
    # not trust THAT name either - its description mentions are almost always
    # unrelated). DescriptionGroup stays trusted so transitive chains propagate.
    $independentReasons = @(@($Result.Reasons) |
        Where-Object { $_.Pattern -ne 'MemberVendorUser' -and $_.Pattern -ne 'NestedVendorGroup' })
    if ($independentReasons.Count -gt 0) { return $true }
    return [bool]$Result.AllMembersVendor
}
