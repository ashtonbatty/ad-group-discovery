BeforeAll { . "$PSScriptRoot/_TestHelpers.ps1" }

Describe 'ConvertTo-IdentityTokens' {
    It 'builds unique tokens from sam, UUserId, and AD mail only' {
        $t = ConvertTo-IdentityTokens -SamAccountName 'jsmith' -UUserId 'U12345' -Mail 'jsmith@vendor.com'
        $t | Should -Contain 'jsmith'
        $t | Should -Contain 'U12345'
        $t | Should -Contain 'jsmith@vendor.com'
        $t | Should -Not -Contain 'John Smith'
        $t | Should -Not -Contain 'J. Smith'
    }

    It 'returns tokens longest-first (ties alphabetical) so consumers can scan in order' {
        # Get-DescriptionMatchReasons consumes tokens in array order on the
        # per-group hot path; the producer owns the longest-first ordering so
        # the most specific token (email over sam) is recorded on a hit.
        $t = @(ConvertTo-IdentityTokens -SamAccountName 'jsmith' -UUserId 'U12345' -Mail 'jsmith@vendor.com')
        $t | Should -Be @('jsmith@vendor.com', 'jsmith', 'U12345')
    }

    It 'drops empty and very short (<3 char) tokens' {
        $t = ConvertTo-IdentityTokens -SamAccountName 'ab' -UUserId 'xy' -Mail ''
        $t | Should -Not -Contain 'ab'
        $t | Should -Not -Contain 'xy'
        $t | Should -Be @()
    }
}
