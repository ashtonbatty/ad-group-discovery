function Get-OwnerMatchReason {
    [CmdletBinding()]
    param([string]$ManagedBy, [object[]]$VendorUsers, [hashtable]$Index)
    $u = Resolve-VendorPrincipal -Identity $ManagedBy -VendorUsers $VendorUsers -Index $Index
    if ($u) { [pscustomobject]@{ Pattern = 'Owner'; Value = $u.DisplayName } }
}
