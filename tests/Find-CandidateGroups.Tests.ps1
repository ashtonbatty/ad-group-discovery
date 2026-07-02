BeforeAll {
    . "$PSScriptRoot/_TestHelpers.ps1"
    $script:users = @(New-TestVendorUser -WithTokens)
}

Describe 'Find-CandidateGroups' {
    It 'scores a name-keyword group as High and tags it Discovered' {
        $g = New-TestGroup 'Acme Admins' 'CN=Acme Admins,OU=Groups,DC=corp,DC=example,DC=com'
        $res = @(Find-CandidateGroups -Groups @($g) -Keywords @('Acme') -VendorUsers $users -KnownKeys @{} -ExcludeKeys @{})
        $res[0].Confidence | Should -Be 'High'
        $res[0].Source     | Should -Be 'Discovered'
    }
    It 'marks a known group Confirmed' {
        $g = New-TestGroup 'Helpdesk' 'CN=Helpdesk,OU=Groups,DC=corp,DC=example,DC=com'
        $known = @{ 'corp.example.com|helpdesk' = $true }
        $res = @(Find-CandidateGroups -Groups @($g) -Keywords @() -VendorUsers $users -KnownKeys $known -ExcludeKeys @{})
        $res[0].Confidence | Should -Be 'Confirmed'
        $res[0].Source     | Should -Be 'Known'
    }
    It 'omits excluded groups entirely' {
        $g = New-TestGroup 'Acme Admins' 'CN=Acme Admins,OU=Groups,DC=corp,DC=example,DC=com'
        $excl = @{ 'corp.example.com|acme admins' = $true }
        @(Find-CandidateGroups -Groups @($g) -Keywords @('Acme') -VendorUsers $users -KnownKeys @{} -ExcludeKeys $excl).Count | Should -Be 0
    }
    It 'returns a None-confidence result for a group with no signal (kept for closure)' {
        $g = New-TestGroup 'Finance' 'CN=Finance,OU=Groups,DC=corp,DC=example,DC=com'
        (@(Find-CandidateGroups -Groups @($g) -Keywords @('Acme') -VendorUsers $users -KnownKeys @{} -ExcludeKeys @{}))[0].Confidence | Should -Be 'None'
    }
    It 'flags AllMembersVendor when every member resolves to a vendor user' {
        $g = New-TestGroup 'Support Staff' 'CN=Support Staff,OU=Groups,DC=corp,DC=example,DC=com' `
            -Member @($users[0].DistinguishedName)
        $res = @(Find-CandidateGroups -Groups @($g) -Keywords @() -VendorUsers $users -KnownKeys @{} -ExcludeKeys @{})
        $res[0].AllMembersVendor | Should -BeTrue
    }
    It 'does not flag AllMembersVendor when membership is mixed' {
        $g = New-TestGroup 'Domain Admins' 'CN=Domain Admins,CN=Users,DC=corp,DC=example,DC=com' `
            -Member @($users[0].DistinguishedName, 'CN=Jane Roe,OU=Staff,DC=corp,DC=example,DC=com')
        $res = @(Find-CandidateGroups -Groups @($g) -Keywords @() -VendorUsers $users -KnownKeys @{} -ExcludeKeys @{})
        $res[0].AllMembersVendor | Should -BeFalse
    }
    It 'does not flag AllMembersVendor on an empty group' {
        $g = New-TestGroup 'Empty Shell' 'CN=Empty Shell,OU=Groups,DC=corp,DC=example,DC=com'
        $res = @(Find-CandidateGroups -Groups @($g) -Keywords @() -VendorUsers $users -KnownKeys @{} -ExcludeKeys @{})
        $res[0].AllMembersVendor | Should -BeFalse
    }
}
