function Resolve-ResultDisplay {
    [CmdletBinding()]
    param([object[]]$Results, [hashtable]$DnIndex, [object[]]$VendorUsers)
    $vendorIndex = New-VendorPrincipalIndex -VendorUsers $VendorUsers
    $groupIndex = @{}
    foreach ($g in @($Results)) {
        if ($g.DistinguishedName) { $groupIndex[$g.DistinguishedName.ToLower()] = $g }
    }
    foreach ($r in $Results) {
        $owner = Resolve-DisplayName -Identity $r.ManagedBy -DnIndex $DnIndex
        $memberObjectIndex = @{}
        foreach ($memberObject in @($r.MemberDirectoryObjects)) {
            if ($memberObject.DistinguishedName) {
                $memberObjectIndex[$memberObject.DistinguishedName.ToLower()] = $memberObject
            }
        }
        $members = New-Object System.Collections.Generic.List[string]
        $memberDetails = New-Object System.Collections.Generic.List[object]
        foreach ($m in @($r.Member)) {
            if ([string]::IsNullOrWhiteSpace($m)) { continue }
            $memberKey = $m.ToLower()
            $name = Resolve-DisplayName -Identity $m -DnIndex $DnIndex
            $vendor = Resolve-VendorPrincipal -Identity $m -VendorUsers $VendorUsers -Index $vendorIndex
            $directoryObject = $null
            if ($memberObjectIndex.ContainsKey($memberKey)) { $directoryObject = $memberObjectIndex[$memberKey] }
            $memberType = 'Other'
            $samAccountName = ''
            $displayName = $name

            if ($directoryObject) {
                if ($directoryObject.SamAccountName) { $samAccountName = $directoryObject.SamAccountName }
                if ($directoryObject.DisplayName) {
                    $displayName = $directoryObject.DisplayName
                } elseif ($directoryObject.Name) {
                    $displayName = $directoryObject.Name
                }
            }

            if ($vendor) {
                $memberType = 'Known'
                $samAccountName = $vendor.SamAccountName
                if ($vendor.DisplayName) { $displayName = $vendor.DisplayName }
                $members.Add("*$displayName")
            } else {
                if ($groupIndex.ContainsKey($memberKey)) {
                    $memberType = 'NestedGroup'
                    if ($groupIndex[$memberKey].Name) { $displayName = $groupIndex[$memberKey].Name }
                } elseif ($directoryObject -and "$($directoryObject.ObjectClass)" -ieq 'group') {
                    $memberType = 'NestedGroup'
                }
                $members.Add($displayName)
            }

            $memberDetails.Add([pscustomobject]@{
                MemberType        = $memberType
                SamAccountName    = $samAccountName
                DisplayName       = $displayName
                DistinguishedName = $m
            })
        }
        $memberOf = New-Object System.Collections.Generic.List[string]
        foreach ($mo in @($r.MemberOf)) {
            if ([string]::IsNullOrWhiteSpace($mo)) { continue }
            $memberOf.Add((Resolve-DisplayName -Identity $mo -DnIndex $DnIndex))
        }
        $r | Add-Member -NotePropertyName Owner -NotePropertyValue $owner -Force
        $r | Add-Member -NotePropertyName Members -NotePropertyValue $members.ToArray() -Force
        $r | Add-Member -NotePropertyName MemberDetails -NotePropertyValue $memberDetails.ToArray() -Force
        $r | Add-Member -NotePropertyName MemberOfDisplay -NotePropertyValue $memberOf.ToArray() -Force
    }
    ,$Results
}
