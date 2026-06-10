BeforeAll {
    . "$PSScriptRoot/_TestHelpers.ps1"
    $script:users = @(New-TestVendorUser -WithTokens)
}

Describe 'Foreign-SID vendor member resolution' {
    It 'resolves a vendor user referenced by foreign-security-principal SID' {
        $fsp = 'CN=S-1-5-21-1-2-3-1001,CN=ForeignSecurityPrincipals,DC=other,DC=example,DC=com'
        $u = Resolve-VendorPrincipal -Identity $fsp -VendorUsers $users
        $u.SamAccountName | Should -Be 'jsmith'
    }
    It 'flags a foreign-SID vendor member with a MemberVendorUser reason in Find-CandidateGroups' {
        $g = New-TestGroup -Name 'Cross Domain App' -Dn 'CN=Cross Domain App,OU=Groups,DC=corp,DC=example,DC=com' `
            -Member @('CN=S-1-5-21-1-2-3-1001,CN=ForeignSecurityPrincipals,DC=corp,DC=example,DC=com')
        $res = @(Find-CandidateGroups -Groups @($g) -Keywords @() -VendorUsers $users -KnownKeys @{} -ExcludeKeys @{})
        ($res[0].Reasons | Where-Object Pattern -eq 'MemberVendorUser').Value | Should -Be 'John Smith'
        $res[0].Confidence | Should -Be 'Low'
    }
}
