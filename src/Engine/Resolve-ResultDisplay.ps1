function Resolve-ResultDisplay {
    [CmdletBinding()]
    param([object[]]$Results, [hashtable]$DnIndex, [object[]]$VendorUsers)
    foreach ($r in $Results) {
        $owner = Resolve-DisplayName -Identity $r.ManagedBy -DnIndex $DnIndex
        $members = @()
        foreach ($m in @($r.Member)) {
            if ([string]::IsNullOrWhiteSpace($m)) { continue }
            $name = Resolve-DisplayName -Identity $m -DnIndex $DnIndex
            $isVendor = [bool](Resolve-VendorPrincipal -Identity $m -VendorUsers $VendorUsers)
            if ($isVendor) { $members += "*$name" } else { $members += $name }
        }
        $memberOf = @()
        foreach ($mo in @($r.MemberOf)) {
            if ([string]::IsNullOrWhiteSpace($mo)) { continue }
            $memberOf += Resolve-DisplayName -Identity $mo -DnIndex $DnIndex
        }
        $r | Add-Member -NotePropertyName Owner -NotePropertyValue $owner -Force
        $r | Add-Member -NotePropertyName Members -NotePropertyValue $members -Force
        $r | Add-Member -NotePropertyName MemberOfDisplay -NotePropertyValue $memberOf -Force
    }
    ,$Results
}
