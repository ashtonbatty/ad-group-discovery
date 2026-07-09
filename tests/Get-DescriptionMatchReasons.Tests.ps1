BeforeAll {
    . "$PSScriptRoot/_TestHelpers.ps1"
    $script:users = @(New-TestVendorUser -WithTokens)
}

Describe 'Get-DescriptionMatchReasons' {
    It 'emits a DescriptionKeyword reason for a keyword in the description' {
        $r = @(Get-DescriptionMatchReasons -Description 'Acme app access' -Info '' -Keywords @('Acme') -VendorUsers @())
        ($r | Where-Object Pattern -eq 'DescriptionKeyword').Value | Should -Be 'Acme'
    }
    It 'emits a DescriptionUser reason when a user token appears (in info too)' {
        $r = @(Get-DescriptionMatchReasons -Description '' -Info 'Owner: jsmith' -Keywords @() -VendorUsers $users)
        ($r | Where-Object Pattern -eq 'DescriptionUser').Value | Should -Match 'jsmith'
    }
    It 'matches directory email but not display name' {
        $email = @(Get-DescriptionMatchReasons -Description 'Owner: jsmith@vendor.com' -Info '' -Keywords @() -VendorUsers $users)
        ($email | Where-Object Pattern -eq 'DescriptionUser').Value | Should -Match 'jsmith@vendor.com'

        $display = @(Get-DescriptionMatchReasons -Description 'Owner: John Smith (other)' -Info '' -Keywords @() -VendorUsers $users)
        @($display | Where-Object Pattern -eq 'DescriptionUser').Count | Should -Be 0
    }
    It 'matches a UUserId token' {
        $r = @(Get-DescriptionMatchReasons -Description 'Owner: U12345' -Info '' -Keywords @() -VendorUsers $users)
        ($r | Where-Object Pattern -eq 'DescriptionUser').Value | Should -Match 'U12345'
    }
    It 'emits at most one DescriptionUser reason per user' {
        $r = @(Get-DescriptionMatchReasons -Description 'jsmith and jsmith@vendor.com' -Info '' -Keywords @() -VendorUsers $users)
        ($r | Where-Object Pattern -eq 'DescriptionUser').Count | Should -Be 1
    }
    It 'consumes tokens in array order - ordering is the producer''s job, not re-sorted per group' {
        # Perf contract: no per-(group,user) sort on the hot path. A user whose
        # tokens arrive shortest-first records the first in-order hit.
        $u = [pscustomobject]@{ SamAccountName = 'jsmith'; Tokens = @('jsmith', 'jsmith@vendor.com') }
        $r = @(Get-DescriptionMatchReasons -Description 'Owner: jsmith@vendor.com' -Info '' -Keywords @() -VendorUsers @($u))
        ($r | Where-Object Pattern -eq 'DescriptionUser').Value | Should -Be 'jsmith ~ jsmith'
    }
    It 'records the most specific token end-to-end with ConvertTo-IdentityTokens ordering' {
        $tokens = ConvertTo-IdentityTokens -SamAccountName 'jsmith' -UUserId 'U12345' -Mail 'jsmith@vendor.com'
        $u = [pscustomobject]@{ SamAccountName = 'jsmith'; Tokens = $tokens }
        $r = @(Get-DescriptionMatchReasons -Description 'jsmith and jsmith@vendor.com' -Info '' -Keywords @() -VendorUsers @($u))
        ($r | Where-Object Pattern -eq 'DescriptionUser').Value | Should -Be 'jsmith ~ jsmith@vendor.com'
    }
}
