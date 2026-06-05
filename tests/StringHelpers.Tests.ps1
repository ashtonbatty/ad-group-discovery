BeforeAll { . "$PSScriptRoot/_TestHelpers.ps1" }

Describe 'Test-KeywordMatch' {
    It 'returns matched keywords case-insensitively' {
        Test-KeywordMatch -Text 'ACME Server Admins' -Keywords @('acme','widget') | Should -Contain 'acme'
    }
    It 'returns nothing for empty text' {
        @(Test-KeywordMatch -Text '' -Keywords @('acme')).Count | Should -Be 0
    }
    It 'treats keyword literally (no wildcard injection)' {
        @(Test-KeywordMatch -Text 'plain text' -Keywords @('*')).Count | Should -Be 0
    }
}

Describe 'Get-OuComponentsFromDn' {
    It 'returns container names excluding the leaf object' {
        $ous = Get-OuComponentsFromDn -DistinguishedName 'CN=Acme Admins,OU=Vendor Groups,OU=IT,DC=corp,DC=example,DC=com'
        $ous | Should -Contain 'Vendor Groups'
        $ous | Should -Contain 'IT'
        $ous | Should -Not -Contain 'Acme Admins'
    }
    It 'returns empty for blank input' {
        @(Get-OuComponentsFromDn -DistinguishedName '').Count | Should -Be 0
    }
}
