BeforeAll { . "$PSScriptRoot/_TestHelpers.ps1" }

Describe 'ConvertTo-LdapFilterValue' {
    It 'escapes backslash before its own escape sequences' {
        # '\*' must become '\5c\2a', not '\5c5c\2a' or '\5c\5c2a'
        ConvertTo-LdapFilterValue -Value '\*' | Should -Be '\5c\2a'
    }
    It 'escapes asterisk' {
        ConvertTo-LdapFilterValue -Value 'a*b' | Should -Be 'a\2ab'
    }
    It 'escapes parentheses' {
        ConvertTo-LdapFilterValue -Value '(x)' | Should -Be '\28x\29'
    }
    It 'escapes NUL' {
        ConvertTo-LdapFilterValue -Value "a`0b" | Should -Be 'a\00b'
    }
    It 'neutralizes a combined hostile payload' {
        ConvertTo-LdapFilterValue -Value '*)(uid=*))(|(uid=*' |
            Should -Be '\2a\29\28uid=\2a\29\29\28|\28uid=\2a'
    }
    It 'passes an ordinary sam through unchanged' {
        ConvertTo-LdapFilterValue -Value 'j.smith-01' | Should -Be 'j.smith-01'
    }
    It 'accepts an empty string' {
        ConvertTo-LdapFilterValue -Value '' | Should -Be ''
    }
}

Describe 'New-SamLdapFilter' {
    It 'wraps multiple names in an OR clause' {
        New-SamLdapFilter -SamAccountNames @('adoe','jsmith') |
            Should -Be '(|(sAMAccountName=adoe)(sAMAccountName=jsmith))'
    }
    It 'emits a bare clause for a single name' {
        New-SamLdapFilter -SamAccountNames @('jsmith') | Should -Be '(sAMAccountName=jsmith)'
    }
    It 'escapes each value' {
        New-SamLdapFilter -SamAccountNames @('a*','b\') |
            Should -Be '(|(sAMAccountName=a\2a)(sAMAccountName=b\5c))'
    }
    It 'returns an empty string for empty input' {
        New-SamLdapFilter -SamAccountNames @() | Should -Be ''
    }
}
