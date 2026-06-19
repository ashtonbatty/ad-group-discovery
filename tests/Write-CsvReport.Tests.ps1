BeforeAll {
    . "$PSScriptRoot/_TestHelpers.ps1"
    $script:tmp = New-TestTempDir -Prefix 'csv'
    $script:results = @(
        [pscustomobject]@{ Domain='corp'; Name='Acme Admins'; DistinguishedName='CN=Acme Admins,DC=c'
            Description='Acme'; Info=''; Owner='John Smith'; Members=@('*John Smith','Bob','Nested Admins')
            MemberDetails=@(
                [pscustomobject]@{ MemberType='Known'; SamAccountName='jsmith'; DisplayName='John Smith'; DistinguishedName='CN=John Smith,DC=c' },
                [pscustomobject]@{ MemberType='Other'; SamAccountName='bjones'; DisplayName='Bob'; DistinguishedName='CN=Bob,DC=c' },
                [pscustomobject]@{ MemberType='NestedGroup'; SamAccountName=''; DisplayName='Nested Admins'; DistinguishedName='CN=Nested Admins,DC=c' }
            )
            MemberOfDisplay=@('All Vendors')
            GroupScope='Global'; GroupCategory='Security'; Mail=$null; AdminCount=$null
            WhenCreated=$null; WhenChanged=$null; Confidence='High'; Score=3
            Reasons=@([pscustomobject]@{Pattern='NameKeyword';Value='Acme'}); Source='Discovered' }
    )
}
AfterAll { Remove-Item -Recurse -Force $script:tmp -ErrorAction SilentlyContinue }

Describe 'Write-CsvReport' {
    It 'writes a group CSV with a key, member counts, and match reasons' {
        $path = Join-Path $tmp 'out.csv'
        $membersPath = Join-Path $tmp 'out-members.csv'
        Write-CsvReport -Results $results -Path $path -MembersPath $membersPath
        Test-Path $path | Should -BeTrue
        $rows = @(Import-Csv $path)
        $rows.Count | Should -Be 1
        $rows[0].GroupKey | Should -Be 'corp\Acme Admins'
        $rows[0].Domain | Should -Be 'corp'
        $rows[0].Name | Should -Be 'Acme Admins'
        $rows[0].MatchReasons | Should -Match 'NameKeyword'
        $rows[0].KnownMemberCount | Should -Be '1'
        $rows[0].OtherMemberCount | Should -Be '1'
        $rows[0].NestedGroupCount | Should -Be '1'
        ($rows[0].PSObject.Properties.Name -contains 'Members') | Should -BeFalse
    }

    It 'writes a normalized member CSV with one row per member' {
        $path = Join-Path $tmp 'groups.csv'
        $membersPath = Join-Path $tmp 'members.csv'
        Write-CsvReport -Results $results -Path $path -MembersPath $membersPath
        Test-Path $membersPath | Should -BeTrue
        $memberRows = @(Import-Csv $membersPath)
        $memberRows.Count | Should -Be 3
        $memberRows[0].GroupKey | Should -Be 'corp\Acme Admins'
        $memberRows[0].SamAccountName | Should -Be 'jsmith'
        $memberRows[0].DisplayName | Should -Be 'John Smith'
        ($memberRows | Where-Object DisplayName -eq 'Bob').SamAccountName | Should -Be 'bjones'
        ($memberRows | Where-Object MemberType -eq 'NestedGroup').DisplayName | Should -Be 'Nested Admins'
    }
}
