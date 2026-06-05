function Resolve-VendorPrincipal {
    [CmdletBinding()]
    param([string]$Identity, [object[]]$VendorUsers)
    if ([string]::IsNullOrWhiteSpace($Identity)) { return $null }
    $sid = $null
    if ($Identity -match '^CN=(S-\d-[\d-]+)') { $sid = $Matches[1] }
    foreach ($u in $VendorUsers) {
        if ($sid -and $u.Sid -and ($u.Sid -ieq $sid)) { return $u }
        if ($u.DistinguishedName -and ($u.DistinguishedName -ieq $Identity)) { return $u }
    }
    return $null
}
