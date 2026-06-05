BeforeAll { . "$PSScriptRoot/_TestHelpers.ps1" }

Describe 'ConvertTo-IdentityTokens' {
    It 'builds unique tokens from AD attributes plus CSV display name' {
        $t = ConvertTo-IdentityTokens -SamAccountName 'jsmith' -DisplayName 'John Smith' `
            -GivenName 'John' -Surname 'Smith' -Cn 'John Smith' -Name 'John Smith' `
            -Upn 'jsmith@vendor.com' -Mail 'jsmith@vendor.com' -CsvDisplayName 'J. Smith'
        $t | Should -Contain 'jsmith'
        $t | Should -Contain 'John Smith'
        $t | Should -Contain 'Smith, John'
        $t | Should -Contain 'J. Smith'
    }

    It 'drops empty and very short (<3 char) tokens' {
        $t = ConvertTo-IdentityTokens -SamAccountName 'ab' -DisplayName 'Al' -Cn 'Alan Bee'
        $t | Should -Not -Contain 'ab'
        $t | Should -Not -Contain 'Al'
        $t | Should -Contain 'Alan Bee'
    }
}
