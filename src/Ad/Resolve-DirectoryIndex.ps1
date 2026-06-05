function Resolve-DirectoryIndex {
    [CmdletBinding()]
    param([object[]]$VendorUsers, [object[]]$Groups)
    $idx = @{}
    foreach ($u in $VendorUsers) {
        if ($u.DistinguishedName) { $idx[$u.DistinguishedName.ToLower()] = $u.DisplayName }
    }
    foreach ($g in $Groups) {
        if ($g.DistinguishedName) { $idx[$g.DistinguishedName.ToLower()] = $g.Name }
    }
    $idx
}
