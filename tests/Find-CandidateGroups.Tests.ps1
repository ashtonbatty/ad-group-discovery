BeforeAll {
    . "$PSScriptRoot/_TestHelpers.ps1"
    $script:users = @(
        [pscustomobject]@{ SamAccountName='jsmith'; DisplayName='John Smith'
            Sid='S-1-5-21-1-2-3-1001'; DistinguishedName='CN=John Smith,OU=Vendor,DC=corp,DC=example,DC=com'
            Tokens=@('jsmith','John Smith') }
    )
    function New-Group($name,$dn,$desc='',$managedBy='',$member=@()) {
        [pscustomobject]@{ Domain='corp.example.com'; Name=$name; DistinguishedName=$dn
            Description=$desc; Info=''; ManagedBy=$managedBy; Member=$member; MemberOf=@()
            GroupScope='Global'; GroupCategory='Security'; Mail=$null; AdminCount=$null
            WhenCreated=$null; WhenChanged=$null }
    }
}

Describe 'Find-CandidateGroups' {
    It 'scores a name-keyword group as High and tags it Discovered' {
        $g = New-Group 'Acme Admins' 'CN=Acme Admins,OU=Groups,DC=corp,DC=example,DC=com'
        $res = @(Find-CandidateGroups -Groups @($g) -Keywords @('Acme') -VendorUsers $users -KnownKeys @{} -ExcludeKeys @{})
        $res[0].Confidence | Should -Be 'High'
        $res[0].Source     | Should -Be 'Discovered'
    }
    It 'marks a known group Confirmed' {
        $g = New-Group 'Helpdesk' 'CN=Helpdesk,OU=Groups,DC=corp,DC=example,DC=com'
        $known = @{ 'corp.example.com|helpdesk' = $true }
        $res = @(Find-CandidateGroups -Groups @($g) -Keywords @() -VendorUsers $users -KnownKeys $known -ExcludeKeys @{})
        $res[0].Confidence | Should -Be 'Confirmed'
        $res[0].Source     | Should -Be 'Known'
    }
    It 'omits excluded groups entirely' {
        $g = New-Group 'Acme Admins' 'CN=Acme Admins,OU=Groups,DC=corp,DC=example,DC=com'
        $excl = @{ 'corp.example.com|acme admins' = $true }
        @(Find-CandidateGroups -Groups @($g) -Keywords @('Acme') -VendorUsers $users -KnownKeys @{} -ExcludeKeys $excl).Count | Should -Be 0
    }
    It 'returns a None-confidence result for a group with no signal (kept for closure)' {
        $g = New-Group 'Finance' 'CN=Finance,OU=Groups,DC=corp,DC=example,DC=com'
        (@(Find-CandidateGroups -Groups @($g) -Keywords @('Acme') -VendorUsers $users -KnownKeys @{} -ExcludeKeys @{}))[0].Confidence | Should -Be 'None'
    }
}
