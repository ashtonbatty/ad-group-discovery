BeforeAll {
    . "$PSScriptRoot/_TestHelpers.ps1"
    $script:users = @(
        [pscustomobject]@{ SamAccountName='jsmith'; DisplayName='John Smith'
            Sid='S-1-5-21-1-2-3-1001'; DistinguishedName='CN=John Smith,OU=Vendor,DC=corp,DC=example,DC=com' }
    )
}

Describe 'Resolve-VendorPrincipal' {
    It 'matches by distinguished name (case-insensitive)' {
        (Resolve-VendorPrincipal -Identity 'cn=john smith,ou=vendor,dc=corp,dc=example,dc=com' -VendorUsers $users).SamAccountName | Should -Be 'jsmith'
    }
    It 'matches a foreign security principal by SID' {
        (Resolve-VendorPrincipal -Identity 'CN=S-1-5-21-1-2-3-1001,CN=ForeignSecurityPrincipals,DC=x,DC=y' -VendorUsers $users).SamAccountName | Should -Be 'jsmith'
    }
    It 'returns null for a non-vendor principal' {
        Resolve-VendorPrincipal -Identity 'CN=Someone Else,DC=corp,DC=example,DC=com' -VendorUsers $users | Should -BeNullOrEmpty
    }
}
