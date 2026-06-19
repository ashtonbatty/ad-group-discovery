BeforeAll {
    . "$PSScriptRoot/_TestHelpers.ps1"
    $script:users = @(New-TestVendorUser)
    $script:dnIndex = @{ 'cn=john smith,ou=vendor,dc=corp,dc=example,dc=com' = 'John Smith' }
    function New-R($name,$conf,$member=@(),$memberof=@(),$managedby='',$dn="CN=$name,DC=c") {
        [pscustomobject]@{ Domain='corp'; Name=$name; DistinguishedName=$dn; Confidence=$conf; Score=9
            Member=@($member); MemberOf=@($memberof); ManagedBy=$managedby }
    }
}

Describe 'Select-DiscoveryResults' {
    It 'drops None and keeps Low+ by default' {
        $in = @((New-R 'a' 'None'), (New-R 'b' 'Low'), (New-R 'c' 'High'))
        (Select-DiscoveryResults -Results $in).Name | Should -Be @('b','c')
    }
    It 'honours a higher MinimumConfidence' {
        $in = @((New-R 'b' 'Low'), (New-R 'c' 'High'))
        (Select-DiscoveryResults -Results $in -MinimumConfidence 'High').Name | Should -Be @('c')
    }
}

Describe 'Resolve-DisplayName' {
    It 'resolves a DN via the index' {
        Resolve-DisplayName -Identity 'CN=John Smith,OU=Vendor,DC=corp,DC=example,DC=com' -DnIndex $dnIndex | Should -Be 'John Smith'
    }
    It 'marks an unresolved foreign SID' {
        Resolve-DisplayName -Identity 'CN=S-1-5-21-9-9-9-9,CN=ForeignSecurityPrincipals,DC=x' -DnIndex @{} | Should -Match 'unresolved'
    }
}

Describe 'Resolve-ResultDisplay' {
    It 'adds Owner and flags vendor members with a leading asterisk' {
        $r = New-R 'Acme Admins' 'High' @('CN=John Smith,OU=Vendor,DC=corp,DC=example,DC=com','CN=Bob,DC=x') @() 'CN=John Smith,OU=Vendor,DC=corp,DC=example,DC=com'
        $out = Resolve-ResultDisplay -Results @($r) -DnIndex $dnIndex -VendorUsers $users
        $out[0].Owner | Should -Be 'John Smith'
        (@($out[0].Members | Where-Object { $_ -like '*John Smith' }))[0] | Should -Be '*John Smith'
    }
    It 'adds structured member details with sam account names for known members' {
        $bobDn = 'CN=Bob Jones,DC=x'
        $r = New-R 'Acme Admins' 'High' @('CN=John Smith,OU=Vendor,DC=corp,DC=example,DC=com',$bobDn)
        $r | Add-Member -NotePropertyName MemberDirectoryObjects -NotePropertyValue @(
            [pscustomobject]@{ DistinguishedName=$bobDn; SamAccountName='bjones'
                DisplayName='Bob Jones'; Name='Bob Jones'; ObjectClass='user' }
        )
        $out = Resolve-ResultDisplay -Results @($r) -DnIndex $dnIndex -VendorUsers $users
        $out[0].MemberDetails[0].MemberType | Should -Be 'Known'
        $out[0].MemberDetails[0].SamAccountName | Should -Be 'jsmith'
        $out[0].MemberDetails[0].DisplayName | Should -Be 'John Smith'
        $out[0].MemberDetails[1].MemberType | Should -Be 'Other'
        $out[0].MemberDetails[1].SamAccountName | Should -Be 'bjones'
        $out[0].MemberDetails[1].DisplayName | Should -Be 'Bob Jones'
    }
    It 'classifies selected group members as nested groups' {
        $child = New-R 'Nested Admins' 'High' @() @() '' 'CN=Nested Admins,DC=c'
        $parent = New-R 'Acme Admins' 'High' @('CN=Nested Admins,DC=c') @() '' 'CN=Acme Admins,DC=c'
        $out = Resolve-ResultDisplay -Results @($parent,$child) -DnIndex @{} -VendorUsers $users
        ($out | Where-Object Name -eq 'Acme Admins').MemberDetails[0].MemberType | Should -Be 'NestedGroup'
    }
}
