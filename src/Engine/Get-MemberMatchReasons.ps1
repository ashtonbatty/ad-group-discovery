function Get-MemberMatchReasons {
    [CmdletBinding()]
    param([string[]]$Member, [object[]]$VendorUsers, [hashtable]$Index)
    $reasons = New-Object System.Collections.Generic.List[object]
    foreach ($m in @($Member)) {
        $u = Resolve-VendorPrincipal -Identity $m -VendorUsers $VendorUsers -Index $Index
        if ($u) { $reasons.Add([pscustomobject]@{ Pattern = 'MemberVendorUser'; Value = $u.DisplayName }) }
    }
    $reasons.ToArray()
}
