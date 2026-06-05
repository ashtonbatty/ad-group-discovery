function Resolve-VendorPrincipal {
    [CmdletBinding()]
    param([string]$Identity, [object[]]$VendorUsers, [hashtable]$Index)
    if ([string]::IsNullOrWhiteSpace($Identity)) { return $null }
    $sid = $null
    if ($Identity -match '^CN=(S-\d-[\d-]+)') { $sid = $Matches[1] }
    if ($Index) {
        if ($sid) {
            $sk = 'sid:' + $sid.ToLower()
            if ($Index.ContainsKey($sk)) { return $Index[$sk] }
        }
        $dk = 'dn:' + $Identity.ToLower()
        if ($Index.ContainsKey($dk)) { return $Index[$dk] }
        return $null
    }
    foreach ($u in $VendorUsers) {
        if ($sid -and $u.Sid -and ($u.Sid -ieq $sid)) { return $u }
        if ($u.DistinguishedName -and ($u.DistinguishedName -ieq $Identity)) { return $u }
    }
    return $null
}
