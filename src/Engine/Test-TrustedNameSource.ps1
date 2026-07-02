function Test-TrustedNameSource {
    # Single authority on whether a result's name may seed description-name
    # trust. Used by Expand-VendorGroupClosure (to add DescriptionGroup reasons)
    # and by Get-AdDiscoveryData (to decide which names are worth LDAP
    # description searches), so the fetch layer can never trust more or less
    # than the engine does.
    #
    # Vendor membership alone is not independent evidence: a vendor account
    # sitting in a shared or built-in group ("Domain Admins") must not turn
    # that group's name into a trusted token. Member-only groups still qualify
    # when the membership is exclusively vendor users (vendor-dedicated) or the
    # group is listed in known.csv.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Result,
        [Parameter(Mandatory)][hashtable]$Rank
    )
    if ($Result.IsKnown) { return $true }
    if ($Rank[$Result.Confidence] -lt $Rank['Low']) { return $false }
    $nonMemberReasons = @(@($Result.Reasons) | Where-Object { $_.Pattern -ne 'MemberVendorUser' })
    if ($nonMemberReasons.Count -gt 0) { return $true }
    return [bool]$Result.AllMembersVendor
}
