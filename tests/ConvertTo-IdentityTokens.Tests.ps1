BeforeAll { . "$PSScriptRoot/_TestHelpers.ps1" }

Describe 'ConvertTo-IdentityTokens' {
    It 'builds unique tokens from sam and AD mail only' {
        $t = ConvertTo-IdentityTokens -SamAccountName 'jsmith' -Mail 'jsmith@vendor.com'
        $t | Should -Contain 'jsmith'
        $t | Should -Contain 'jsmith@vendor.com'
        $t | Should -Not -Contain 'John Smith'
        $t | Should -Not -Contain 'J. Smith'
    }

    It 'drops empty and very short (<3 char) tokens' {
        $t = ConvertTo-IdentityTokens -SamAccountName 'ab' -Mail ''
        $t | Should -Not -Contain 'ab'
        $t | Should -Be @()
    }
}
