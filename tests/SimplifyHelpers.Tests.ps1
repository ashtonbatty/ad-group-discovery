BeforeAll {
    . "$PSScriptRoot/_TestHelpers.ps1"
    $script:users = @(
        [pscustomobject]@{ SamAccountName='jsmith'; DisplayName='John Smith'
            Sid='S-1-5-21-1-2-3-1001'; DistinguishedName='CN=John Smith,OU=Vendor,DC=corp,DC=example,DC=com' }
    )
}

Describe 'Get-ConfidenceRank' {
    It 'orders bands None<Low<Medium<High<Confirmed' {
        $r = Get-ConfidenceRank
        $r['None']      | Should -Be 0
        $r['Low']       | Should -Be 1
        $r['Medium']    | Should -Be 2
        $r['High']      | Should -Be 3
        $r['Confirmed'] | Should -Be 4
    }
}

Describe 'Get-GroupLookupKey' {
    It 'builds a lowercased domain|identity key' {
        Get-GroupLookupKey -Domain 'CORP.example.com' -Identity 'Acme Admins' | Should -Be 'corp.example.com|acme admins'
    }
}

Describe 'New-VendorPrincipalIndex / Resolve-VendorPrincipal -Index' {
    It 'indexes vendor users by DN and SID' {
        $idx = New-VendorPrincipalIndex -VendorUsers $users
        $idx.ContainsKey('dn:cn=john smith,ou=vendor,dc=corp,dc=example,dc=com') | Should -BeTrue
        $idx.ContainsKey('sid:s-1-5-21-1-2-3-1001') | Should -BeTrue
    }
    It 'resolves by DN via the index (parity with the scan path)' {
        $idx = New-VendorPrincipalIndex -VendorUsers $users
        $dn  = 'cn=john smith,ou=vendor,dc=corp,dc=example,dc=com'
        (Resolve-VendorPrincipal -Identity $dn -Index $idx).SamAccountName | Should -Be 'jsmith'
    }
    It 'resolves a foreign-security-principal SID via the index' {
        $idx = New-VendorPrincipalIndex -VendorUsers $users
        $fsp = 'CN=S-1-5-21-1-2-3-1001,CN=ForeignSecurityPrincipals,DC=other,DC=example,DC=com'
        (Resolve-VendorPrincipal -Identity $fsp -Index $idx).SamAccountName | Should -Be 'jsmith'
    }
    It 'returns null via the index for a non-vendor principal' {
        $idx = New-VendorPrincipalIndex -VendorUsers $users
        Resolve-VendorPrincipal -Identity 'CN=Someone Else,DC=corp,DC=example,DC=com' -Index $idx | Should -BeNullOrEmpty
    }
}
