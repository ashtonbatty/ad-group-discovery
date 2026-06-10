BeforeAll { . "$PSScriptRoot/_TestHelpers.ps1" }

Describe 'Protect-CsvCell' {
    It 'prefixes a leading formula character with an apostrophe' {
        Protect-CsvCell -Value '=1+1'      | Should -Be "'=1+1"
        Protect-CsvCell -Value '+SUM(A1)'  | Should -Be "'+SUM(A1)"
        Protect-CsvCell -Value '-2+3'      | Should -Be "'-2+3"
        Protect-CsvCell -Value '@foo'      | Should -Be "'@foo"
    }
    It 'prefixes leading control-character formula triggers with an apostrophe' {
        Protect-CsvCell -Value ([string]([char]9) + '=1+1')  | Should -Be ([string]"'$([char]9)=1+1")
        Protect-CsvCell -Value ([string]([char]10) + '=1+1') | Should -Be ([string]"'$([char]10)=1+1")
        Protect-CsvCell -Value ([string]([char]13) + '=1+1') | Should -Be ([string]"'$([char]13)=1+1")
    }
    It 'leaves safe values unchanged' {
        Protect-CsvCell -Value 'Acme Admins' | Should -Be 'Acme Admins'
        Protect-CsvCell -Value '*John Smith' | Should -Be '*John Smith'
    }
    It 'returns null and empty unchanged' {
        Protect-CsvCell -Value $null | Should -BeNullOrEmpty
        Protect-CsvCell -Value ''    | Should -Be ''
    }
}

Describe 'Write-CsvReport CSV-injection hardening' {
    BeforeAll {
        $script:tmp = New-TestTempDir -Prefix 'csvinj'
    }
    AfterAll { Remove-Item -Recurse -Force $script:tmp -ErrorAction SilentlyContinue }

    It 'neutralizes a formula-injecting description when writing the CSV' {
        $results = @(
            [pscustomobject]@{ Domain='corp'; Name='Acme'; DistinguishedName='CN=Acme,DC=c'
                Description='=cmd|calc'; Info=''; Owner=''; Members=@(); MemberOfDisplay=@()
                GroupScope='Global'; GroupCategory='Security'; Mail=$null; AdminCount=$null
                WhenCreated=$null; WhenChanged=$null; Confidence='High'; Score=3
                Reasons=@([pscustomobject]@{Pattern='NameKeyword';Value='Acme'}); Source='Discovered' }
        )
        $path = Join-Path $tmp 'inj.csv'
        Write-CsvReport -Results $results -Path $path
        $rows = @(Import-Csv $path)
        $rows[0].Description | Should -Be "'=cmd|calc"
    }
}
