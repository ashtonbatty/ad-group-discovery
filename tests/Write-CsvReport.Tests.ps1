BeforeAll {
    . "$PSScriptRoot/_TestHelpers.ps1"
    $script:tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("csv_" + [guid]::NewGuid())
    New-Item -ItemType Directory -Path $script:tmp | Out-Null
    $script:results = @(
        [pscustomobject]@{ Domain='corp'; Name='Acme Admins'; DistinguishedName='CN=Acme Admins,DC=c'
            Description='Acme'; Info=''; Owner='John Smith'; Members=@('*John Smith','Bob'); MemberOfDisplay=@('All Vendors')
            GroupScope='Global'; GroupCategory='Security'; Mail=$null; AdminCount=$null
            WhenCreated=$null; WhenChanged=$null; Confidence='High'; Score=3
            Reasons=@([pscustomobject]@{Pattern='NameKeyword';Value='Acme'}); Source='Discovered' }
    )
}
AfterAll { Remove-Item -Recurse -Force $script:tmp -ErrorAction SilentlyContinue }

Describe 'Write-CsvReport' {
    It 'writes a CSV with one row per group and a MatchReasons column' {
        $path = Join-Path $tmp 'out.csv'
        Write-CsvReport -Results $results -Path $path
        Test-Path $path | Should -BeTrue
        $rows = @(Import-Csv $path)
        $rows.Count | Should -Be 1
        $rows[0].Name | Should -Be 'Acme Admins'
        $rows[0].MatchReasons | Should -Match 'NameKeyword'
        $rows[0].Members | Should -Match 'John Smith'
    }
}
