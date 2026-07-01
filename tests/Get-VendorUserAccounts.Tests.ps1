BeforeAll { . "$PSScriptRoot/_TestHelpers.ps1" }

Describe 'Get-VendorUserAccounts' {
    It 'projects one row per user with the audit fields' {
        $users = @(
            [pscustomobject]@{
                Domain='corp.example.com'; SamAccountName='svc-acme'; DisplayName='ACME Svc'
                Enabled=$true; LockedOut=$false; Description='vendor svc'
                AccountExpirationDate=$null; LastLogonDate=$null; PasswordLastSet=$null
                PasswordNeverExpires=$false; BadLogonCount=0; PasswordExpiryComputed='0'
            }
        )
        $rows = @(Get-VendorUserAccounts -VendorUsers $users)
        $rows.Count | Should -Be 1
        $rows[0].UserSamAccountName | Should -Be 'svc-acme'
        $rows[0].Enabled | Should -Be $true
        $rows[0].Description | Should -Be 'vendor svc'
    }

    It 'blanks PasswordExpiry for the 0 (must-change) sentinel' {
        $users = @([pscustomobject]@{ Domain='c'; SamAccountName='a'; DisplayName='A'
            Enabled=$true; LockedOut=$false; Description=''
            AccountExpirationDate=$null; LastLogonDate=$null; PasswordLastSet=$null
            PasswordNeverExpires=$false; BadLogonCount=0; PasswordExpiryComputed='0' })
        (@(Get-VendorUserAccounts -VendorUsers $users))[0].PasswordExpiry | Should -Be ''
    }

    It 'blanks PasswordExpiry for the Int64.MaxValue (never) sentinel' {
        $users = @([pscustomobject]@{ Domain='c'; SamAccountName='a'; DisplayName='A'
            Enabled=$true; LockedOut=$false; Description=''
            AccountExpirationDate=$null; LastLogonDate=$null; PasswordLastSet=$null
            PasswordNeverExpires=$true; BadLogonCount=0; PasswordExpiryComputed='9223372036854775807' })
        (@(Get-VendorUserAccounts -VendorUsers $users))[0].PasswordExpiry | Should -Be ''
    }

    It 'converts a real FileTime to a formatted date' {
        $ft = '133612200000000000'
        $expected = [datetime]::FromFileTime([int64]$ft).ToString('yyyy-MM-dd HH:mm:ss')
        $users = @([pscustomobject]@{ Domain='c'; SamAccountName='a'; DisplayName='A'
            Enabled=$true; LockedOut=$false; Description=''
            AccountExpirationDate=$null; LastLogonDate=$null; PasswordLastSet=$null
            PasswordNeverExpires=$false; BadLogonCount=0; PasswordExpiryComputed=$ft })
        (@(Get-VendorUserAccounts -VendorUsers $users))[0].PasswordExpiry | Should -Be $expected
    }

    It 'formats a DateTime date field and passes a string date through' {
        $users = @([pscustomobject]@{ Domain='c'; SamAccountName='a'; DisplayName='A'
            Enabled=$true; LockedOut=$false; Description=''
            AccountExpirationDate=[datetime]'2026-12-31T00:00:00'; LastLogonDate='2026-06-29T17:55:10'; PasswordLastSet=$null
            PasswordNeverExpires=$false; BadLogonCount=0; PasswordExpiryComputed=$null })
        $row = (@(Get-VendorUserAccounts -VendorUsers $users))[0]
        $row.AccountExpirationDate | Should -Be '2026-12-31 00:00:00'
        $row.LastLogonDate | Should -Be '2026-06-29T17:55:10'
        $row.PasswordExpiry | Should -Be ''
    }
}
