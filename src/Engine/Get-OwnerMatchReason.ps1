function Get-OwnerMatchReason {
    [CmdletBinding()]
    param([string]$ManagedBy, [object[]]$VendorUsers)
    $u = Resolve-VendorPrincipal -Identity $ManagedBy -VendorUsers $VendorUsers
    if ($u) { [pscustomobject]@{ Pattern = 'Owner'; Value = $u.DisplayName } }
}
