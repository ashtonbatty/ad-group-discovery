function Resolve-ResultDisplay {
    [CmdletBinding()]
    param([object[]]$Results, [hashtable]$DnIndex, [object[]]$VendorUsers)
    $vendorIndex = New-VendorPrincipalIndex -VendorUsers $VendorUsers
    foreach ($r in $Results) {
        $owner = Resolve-DisplayName -Identity $r.ManagedBy -DnIndex $DnIndex
        $members = New-Object System.Collections.Generic.List[string]
        foreach ($m in @($r.Member)) {
            if ([string]::IsNullOrWhiteSpace($m)) { continue }
            $name = Resolve-DisplayName -Identity $m -DnIndex $DnIndex
            $isVendor = [bool](Resolve-VendorPrincipal -Identity $m -VendorUsers $VendorUsers -Index $vendorIndex)
            if ($isVendor) { $members.Add("*$name") } else { $members.Add($name) }
        }
        $memberOf = New-Object System.Collections.Generic.List[string]
        foreach ($mo in @($r.MemberOf)) {
            if ([string]::IsNullOrWhiteSpace($mo)) { continue }
            $memberOf.Add((Resolve-DisplayName -Identity $mo -DnIndex $DnIndex))
        }
        $r | Add-Member -NotePropertyName Owner -NotePropertyValue $owner -Force
        $r | Add-Member -NotePropertyName Members -NotePropertyValue $members.ToArray() -Force
        $r | Add-Member -NotePropertyName MemberOfDisplay -NotePropertyValue $memberOf.ToArray() -Force
    }
    ,$Results
}
