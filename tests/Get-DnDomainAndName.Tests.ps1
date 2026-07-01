BeforeAll { . "$PSScriptRoot/_TestHelpers.ps1" }

Describe 'Get-DnDomainAndName' {
    It 'derives domain from DC components and name from the leaf CN' {
        $r = Get-DnDomainAndName -DistinguishedName 'CN=Sales Team,OU=Groups,DC=corp,DC=example,DC=com'
        $r.Domain | Should -Be 'corp.example.com'
        $r.Name   | Should -Be 'Sales Team'
    }
    It 'unescapes an escaped comma in the leaf RDN' {
        $r = Get-DnDomainAndName -DistinguishedName 'CN=Smith\, John,OU=Groups,DC=corp,DC=example,DC=com'
        $r.Name | Should -Be 'Smith, John'
    }
    It 'returns empty strings for blank input' {
        $r = Get-DnDomainAndName -DistinguishedName ''
        $r.Domain | Should -Be ''
        $r.Name   | Should -Be ''
    }
}
