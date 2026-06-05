BeforeAll {
    . "$PSScriptRoot/_TestHelpers.ps1"
    $script:tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("audit_" + [guid]::NewGuid())
    New-Item -ItemType Directory -Path $script:tmp | Out-Null
    Set-Content "$tmp/users.csv"        "SamAccountName,DisplayName`njsmith,John Smith"
    Set-Content "$tmp/domains.csv"      "Domain,Server,Name`ncorp.example.com,dc1,Corp"
    Set-Content "$tmp/keywords.csv"     "Keyword`nAcme"
    Set-Content "$tmp/known.csv"        "Domain,Identity`ncorp.example.com,Acme Admins"
    Set-Content "$tmp/exclude.csv"      "Domain,Identity`ncorp.example.com,Domain Users"
}
AfterAll { Remove-Item -Recurse -Force $script:tmp -ErrorAction SilentlyContinue }

Describe 'Read-AuditInput' {
    It 'reads all five CSVs into a normalized object' {
        $r = Read-AuditInput -UsersCsv "$tmp/users.csv" -DomainsCsv "$tmp/domains.csv" `
            -KeywordsCsv "$tmp/keywords.csv" -KnownGroupsCsv "$tmp/known.csv" -ExcludeGroupsCsv "$tmp/exclude.csv"
        $r.Users[0].SamAccountName | Should -Be 'jsmith'
        $r.Domains[0].Domain       | Should -Be 'corp.example.com'
        $r.Keywords                | Should -Contain 'Acme'
        $r.KnownGroups[0].Identity | Should -Be 'Acme Admins'
        $r.ExcludeGroups[0].Identity | Should -Be 'Domain Users'
    }

    It 'throws a clear error when a required file is missing' {
        { Read-AuditInput -UsersCsv "$tmp/nope.csv" -DomainsCsv "$tmp/domains.csv" `
            -KeywordsCsv "$tmp/keywords.csv" -KnownGroupsCsv "$tmp/known.csv" -ExcludeGroupsCsv "$tmp/exclude.csv" } |
            Should -Throw '*not found*'
    }

    It 'throws when the users CSV lacks SamAccountName' {
        Set-Content "$tmp/bad.csv" "Foo`nbar"
        { Read-AuditInput -UsersCsv "$tmp/bad.csv" -DomainsCsv "$tmp/domains.csv" `
            -KeywordsCsv "$tmp/keywords.csv" -KnownGroupsCsv "$tmp/known.csv" -ExcludeGroupsCsv "$tmp/exclude.csv" } |
            Should -Throw '*SamAccountName*'
    }
}
