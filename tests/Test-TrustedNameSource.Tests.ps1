BeforeAll {
    . "$PSScriptRoot/_TestHelpers.ps1"
    $script:rank = Get-ConfidenceRank
    function New-Candidate($confidence, $reasons, $known = $false, $allVendor = $false) {
        [pscustomobject]@{
            Name = 'Some Group'; DistinguishedName = 'CN=Some Group,DC=c'
            Reasons = @($reasons); Confidence = $confidence
            IsKnown = $known; AllMembersVendor = $allVendor
        }
    }
    function New-Reason($pattern) { [pscustomobject]@{ Pattern = $pattern; Value = 'x' } }
}

Describe 'Test-TrustedNameSource' {
    It 'trusts a known group regardless of its reasons' {
        $r = New-Candidate 'Confirmed' @(New-Reason 'MemberVendorUser') $true
        Test-TrustedNameSource -Result $r -Rank $script:rank | Should -BeTrue
    }
    It 'trusts a group with a non-member reason' {
        $r = New-Candidate 'Medium' @(New-Reason 'DescriptionKeyword')
        Test-TrustedNameSource -Result $r -Rank $script:rank | Should -BeTrue
    }
    It 'trusts a propagated DescriptionGroup reason (transitive trust)' {
        $r = New-Candidate 'Medium' @(New-Reason 'DescriptionGroup')
        Test-TrustedNameSource -Result $r -Rank $script:rank | Should -BeTrue
    }
    It 'does not trust a member-only group with mixed membership' {
        $r = New-Candidate 'Low' @(New-Reason 'MemberVendorUser')
        Test-TrustedNameSource -Result $r -Rank $script:rank | Should -BeFalse
    }
    It 'does not trust a member-only group even at Medium via multiple memberships' {
        $r = New-Candidate 'Medium' @((New-Reason 'MemberVendorUser'), (New-Reason 'MemberVendorUser'))
        Test-TrustedNameSource -Result $r -Rank $script:rank | Should -BeFalse
    }
    It 'trusts a member-only group when every member is a vendor user' {
        $r = New-Candidate 'Low' @(New-Reason 'MemberVendorUser') $false $true
        Test-TrustedNameSource -Result $r -Rank $script:rank | Should -BeTrue
    }
    It 'does not trust a group below Low confidence' {
        $r = New-Candidate 'None' @()
        Test-TrustedNameSource -Result $r -Rank $script:rank | Should -BeFalse
    }
}
