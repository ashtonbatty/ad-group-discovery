BeforeAll {
    . "$PSScriptRoot/_TestHelpers.ps1"
    $script:tmp = New-TestTempDir -Prefix 'uacc'
}
AfterAll { Remove-Item -Recurse -Force $script:tmp -ErrorAction SilentlyContinue }

Describe 'Write-UserAccountReport' {
    It 'writes one row per account with the expected columns' {
        $rows = @(
            [pscustomobject]@{ UserDomain='corp'; UserSamAccountName='jdoe'; UserDisplayName='John Doe'
                Enabled=$true; LockedOut=$true; Description='contractor'
                AccountExpirationDate='2026-12-31 00:00:00'; LastLogonDate='2026-06-29 17:55:10'
                PasswordLastSet='2026-05-18 08:03:44'; PasswordExpiry='2026-08-16 08:03:44'
                PasswordNeverExpires=$false; BadLogonCount=5 }
        )
        $path = Join-Path $tmp 'a.csv'
        Write-UserAccountReport -Rows $rows -Path $path
        $out = @(Import-Csv $path)
        $out.Count | Should -Be 1
        $out[0].UserSamAccountName | Should -Be 'jdoe'
        $out[0].LockedOut | Should -Be 'True'
        $out[0].BadLogonCount | Should -Be '5'
        ($out[0].PSObject.Properties.Name) | Should -Be @('UserDomain','UserSamAccountName','UserDisplayName','Enabled','LockedOut','Description','AccountExpirationDate','LastLogonDate','PasswordLastSet','PasswordExpiry','PasswordNeverExpires','BadLogonCount')
    }
    It 'hardens a formula-injection description' {
        $rows = @([pscustomobject]@{ UserDomain='corp'; UserSamAccountName='a'; UserDisplayName='A'
            Enabled=$true; LockedOut=$false; Description='=HYPERLINK()'
            AccountExpirationDate=''; LastLogonDate=''; PasswordLastSet=''; PasswordExpiry=''
            PasswordNeverExpires=$false; BadLogonCount=0 })
        $path = Join-Path $tmp 'inj.csv'
        Write-UserAccountReport -Rows $rows -Path $path
        (@(Import-Csv $path))[0].Description | Should -Be "'=HYPERLINK()"
    }
}
