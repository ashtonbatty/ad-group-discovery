function New-VendorPrincipalIndex {
    # Build an O(1) lookup index of vendor users keyed by lowercased DN and by SID,
    # so Resolve-VendorPrincipal can avoid an O(n) scan on the per-member hot path.
    # Keys are namespaced ('dn:' / 'sid:') to keep the two spaces distinct.
    [CmdletBinding()]
    param([object[]]$VendorUsers)
    $idx = @{}
    foreach ($u in $VendorUsers) {
        if ($u.DistinguishedName) { $idx['dn:' + $u.DistinguishedName.ToLower()] = $u }
        if ($u.Sid)              { $idx['sid:' + ([string]$u.Sid).ToLower()] = $u }
    }
    $idx
}
