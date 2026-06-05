BeforeAll { . "$PSScriptRoot/_TestHelpers.ps1" }

Describe 'Get-NameMatchReason' {
    It 'emits a NameKeyword reason when the group name contains a keyword' {
        $r = Get-NameMatchReason -GroupName 'Acme Server Admins' -Keywords @('Acme')
        $r.Pattern | Should -Be 'NameKeyword'
        $r.Value   | Should -Be 'Acme'
    }
    It 'emits nothing when no keyword matches' {
        @(Get-NameMatchReason -GroupName 'Finance Team' -Keywords @('Acme')).Count | Should -Be 0
    }
}

Describe 'Get-ContainerMatchReason' {
    It 'emits a ContainerKeyword reason when an OU contains a keyword' {
        $r = Get-ContainerMatchReason -DistinguishedName 'CN=Admins,OU=Acme Vendors,DC=corp,DC=example,DC=com' -Keywords @('Acme')
        $r.Pattern | Should -Be 'ContainerKeyword'
        $r.Value   | Should -Match 'Acme'
    }
    It 'does not match the leaf group name itself' {
        @(Get-ContainerMatchReason -DistinguishedName 'CN=Acme Admins,OU=Groups,DC=corp,DC=example,DC=com' -Keywords @('Acme')).Count | Should -Be 0
    }
}
