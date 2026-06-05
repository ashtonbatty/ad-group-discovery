function Get-MemberMatchReasons {
    [CmdletBinding()]
    param([string[]]$Member, [object[]]$VendorUsers)
    $reasons = @()
    foreach ($m in @($Member)) {
        $u = Resolve-VendorPrincipal -Identity $m -VendorUsers $VendorUsers
        if ($u) { $reasons += [pscustomobject]@{ Pattern = 'MemberVendorUser'; Value = $u.DisplayName } }
    }
    $reasons
}
