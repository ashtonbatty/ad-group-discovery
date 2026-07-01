BeforeAll {
    . "$PSScriptRoot/_TestHelpers.ps1"
    $script:tmp = New-TestTempDir -Prefix 'discovery'
    Set-Content "$tmp/users.csv"        "SamAccountName,UUserId,DisplayName`njsmith,U12345,John Smith"
    Set-Content "$tmp/domains.csv"      "Domain,Server,Name`ncorp.example.com,dc1,Corp"
    Set-Content "$tmp/keywords.csv"     "Keyword`nAcme"
    Set-Content "$tmp/known.csv"        "Domain,Identity`ncorp.example.com,Acme Admins"
    Set-Content "$tmp/exclude.csv"      "Domain,Identity`ncorp.example.com,Domain Users"
}
AfterAll { Remove-Item -Recurse -Force $script:tmp -ErrorAction SilentlyContinue }

Describe 'Read-DiscoveryInput' {
    It 'reads all five CSVs into a normalized object' {
        $r = Read-DiscoveryInput -UsersCsv "$tmp/users.csv" -DomainsCsv "$tmp/domains.csv" `
            -KeywordsCsv "$tmp/keywords.csv" -KnownGroupsCsv "$tmp/known.csv" -ExcludeGroupsCsv "$tmp/exclude.csv"
        $r.Users[0].SamAccountName | Should -Be 'jsmith'
        $r.Users[0].UUserId        | Should -Be 'U12345'
        $r.Domains[0].Domain       | Should -Be 'corp.example.com'
        $r.Keywords                | Should -Contain 'Acme'
        $r.KnownGroups[0].Identity | Should -Be 'Acme Admins'
        $r.ExcludeGroups[0].Identity | Should -Be 'Domain Users'
    }

    It 'throws a clear error when a required file is missing' {
        { Read-DiscoveryInput -UsersCsv "$tmp/nope.csv" -DomainsCsv "$tmp/domains.csv" `
            -KeywordsCsv "$tmp/keywords.csv" -KnownGroupsCsv "$tmp/known.csv" -ExcludeGroupsCsv "$tmp/exclude.csv" } |
            Should -Throw '*not found*'
    }

    It 'throws when the users CSV lacks SamAccountName' {
        Set-Content "$tmp/bad.csv" "Foo`nbar"
        { Read-DiscoveryInput -UsersCsv "$tmp/bad.csv" -DomainsCsv "$tmp/domains.csv" `
            -KeywordsCsv "$tmp/keywords.csv" -KnownGroupsCsv "$tmp/known.csv" -ExcludeGroupsCsv "$tmp/exclude.csv" } |
            Should -Throw '*SamAccountName*'
    }
    It 'throws when a required column is absent even in a header-only CSV with no data rows' {
        Set-Content "$tmp/header-only.csv" "WrongColumn"
        { Read-DiscoveryInput -UsersCsv "$tmp/users.csv" -DomainsCsv "$tmp/header-only.csv" `
            -KeywordsCsv "$tmp/keywords.csv" -KnownGroupsCsv "$tmp/known.csv" -ExcludeGroupsCsv "$tmp/exclude.csv" } |
            Should -Throw '*Domain*'
    }
    It 'throws when the domains CSV is empty' {
        New-Item -ItemType File -Path "$tmp/empty-domains.csv" | Out-Null
        { Read-DiscoveryInput -UsersCsv "$tmp/users.csv" -DomainsCsv "$tmp/empty-domains.csv" `
            -KeywordsCsv "$tmp/keywords.csv" -KnownGroupsCsv "$tmp/known.csv" -ExcludeGroupsCsv "$tmp/exclude.csv" } |
            Should -Throw '*Domain*'
    }
    It 'throws when the users CSV is empty' {
        New-Item -ItemType File -Path "$tmp/empty-users.csv" | Out-Null
        { Read-DiscoveryInput -UsersCsv "$tmp/empty-users.csv" -DomainsCsv "$tmp/domains.csv" `
            -KeywordsCsv "$tmp/keywords.csv" -KnownGroupsCsv "$tmp/known.csv" -ExcludeGroupsCsv "$tmp/exclude.csv" } |
            Should -Throw '*SamAccountName*'
    }
}
