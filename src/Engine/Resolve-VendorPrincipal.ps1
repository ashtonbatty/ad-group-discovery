function Resolve-VendorPrincipal {
    [CmdletBinding()]
    param([string]$Identity, [object[]]$VendorUsers, [hashtable]$Index)
    if ([string]::IsNullOrWhiteSpace($Identity)) { return $null }
    # Hot-path callers pass a prebuilt index; build one on demand otherwise so there
    # is a single matching implementation.
    if (-not $Index) { $Index = New-VendorPrincipalIndex -VendorUsers $VendorUsers }
    $sid = Get-FspSid -DistinguishedName $Identity
    if ($sid) {
        $sk = 'sid:' + $sid.ToLower()
        if ($Index.ContainsKey($sk)) { return $Index[$sk] }
    }
    $dk = 'dn:' + $Identity.ToLower()
    if ($Index.ContainsKey($dk)) { return $Index[$dk] }
    return $null
}
