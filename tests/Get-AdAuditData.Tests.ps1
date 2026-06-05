BeforeAll { . "$PSScriptRoot/_TestHelpers.ps1" }

Describe 'Resolve-DirectoryIndex' {
    It 'maps lowercased DNs to display names for users and groups' {
        $users  = @([pscustomobject]@{ DistinguishedName='CN=John Smith,DC=c'; DisplayName='John Smith' })
        $groups = @([pscustomobject]@{ DistinguishedName='CN=Acme Admins,DC=c'; Name='Acme Admins' })
        $idx = Resolve-DirectoryIndex -VendorUsers $users -Groups $groups
        $idx['cn=john smith,dc=c'] | Should -Be 'John Smith'
        $idx['cn=acme admins,dc=c'] | Should -Be 'Acme Admins'
    }
}

Describe 'Get-AdAuditData' {
    BeforeAll {
        Mock -CommandName Get-ADGroup -MockWith {
            [pscustomobject]@{ Name='Acme Admins'; DistinguishedName='CN=Acme Admins,OU=Groups,DC=corp,DC=example,DC=com'
                description='Acme'; info=$null; managedBy=$null; member=@(); memberof=@()
                GroupScope='Global'; GroupCategory='Security'; mail=$null; adminCount=$null
                whenCreated=$null; whenChanged=$null }
        }
        Mock -CommandName Get-ADUser -MockWith {
            [pscustomobject]@{ SamAccountName='jsmith'; DisplayName='John Smith'; GivenName='John'; Surname='Smith'
                CN='John Smith'; Name='John Smith'; UserPrincipalName='jsmith@vendor.com'; mail='jsmith@vendor.com'
                DistinguishedName='CN=John Smith,OU=Vendor,DC=corp,DC=example,DC=com'
                SID=[pscustomobject]@{ Value='S-1-5-21-1-2-3-1001' } }
        }
    }
    It 'loads groups and resolves vendor users for a domain' {
        $input = [pscustomobject]@{
            Users   = @([pscustomobject]@{ SamAccountName='jsmith'; DisplayName='John Smith' })
            Domains = @([pscustomobject]@{ Domain='corp.example.com'; Server='dc1'; Name='Corp' })
        }
        $data = Get-AdAuditData -InputData $input
        $data.Groups[0].Name | Should -Be 'Acme Admins'
        $data.Groups[0].Domain | Should -Be 'corp.example.com'
        $data.VendorUsers[0].Tokens | Should -Contain 'John Smith'
        $data.FailedDomains.Count | Should -Be 0
    }
    It 'records a failed domain and continues' {
        Mock -CommandName Get-ADGroup -MockWith { throw 'server down' }
        $input = [pscustomobject]@{
            Users   = @()
            Domains = @([pscustomobject]@{ Domain='dead.example.com'; Server=$null; Name=$null })
        }
        $data = Get-AdAuditData -InputData $input
        $data.FailedDomains | Should -Contain 'dead.example.com'
    }
}
