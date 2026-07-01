BeforeAll {
    . "$PSScriptRoot/_TestHelpers.ps1"
    $script:tmp = New-TestTempDir -Prefix 'umem'
}
AfterAll { Remove-Item -Recurse -Force $script:tmp -ErrorAction SilentlyContinue }

Describe 'Write-UserMembershipReport' {
    It 'writes one row per membership with the expected columns' {
        $rows = @(
            [pscustomobject]@{ UserDomain='corp'; UserSamAccountName='jbrooks'; UserDisplayName='Jacob Brooks'
                GroupDomain='corp'; GroupName='NWT Application Owners' }
        )
        $path = Join-Path $tmp 'm.csv'
        Write-UserMembershipReport -Rows $rows -Path $path
        $out = @(Import-Csv $path)
        $out.Count | Should -Be 1
        $out[0].UserSamAccountName | Should -Be 'jbrooks'
        $out[0].GroupName | Should -Be 'NWT Application Owners'
        ($out[0].PSObject.Properties.Name) | Should -Be @('UserDomain','UserSamAccountName','UserDisplayName','GroupDomain','GroupName')
    }
    It 'hardens a formula-injection group name' {
        $rows = @([pscustomobject]@{ UserDomain='corp'; UserSamAccountName='a'; UserDisplayName='A'
            GroupDomain='corp'; GroupName='=cmd()' })
        $path = Join-Path $tmp 'inj.csv'
        Write-UserMembershipReport -Rows $rows -Path $path
        (@(Import-Csv $path))[0].GroupName | Should -Be "'=cmd()"
    }
}
