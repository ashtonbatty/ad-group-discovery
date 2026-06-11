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

Describe 'Get-AdDiscoveryData' {
    BeforeAll {
        Mock -CommandName Get-ADGroup -MockWith {
            [pscustomobject]@{ Name='Acme Admins'; DistinguishedName='CN=Acme Admins,OU=Groups,DC=corp,DC=example,DC=com'
                description='Acme'; info=$null; managedBy=$null; member=@(); memberof=@()
                GroupScope='Global'; GroupCategory='Security'; mail=$null; adminCount=$null
                whenCreated=$null; whenChanged=$null }
        }
        Mock -CommandName Get-ADUser -MockWith {
            [pscustomobject]@{ SamAccountName='jsmith'; DisplayName='John Smith'; GivenName='John'; sn='Smith'
                CN='John Smith'; Name='John Smith'; UserPrincipalName='jsmith@vendor.com'; mail='jsmith@vendor.com'
                DistinguishedName='CN=John Smith,OU=Vendor,DC=corp,DC=example,DC=com'
                objectSid='S-1-5-21-1-2-3-1001' }
        }
    }
    It 'loads groups and resolves vendor users for a domain' {
        $discoveryInput = [pscustomobject]@{
            Users   = @([pscustomobject]@{ SamAccountName='jsmith'; DisplayName='John Smith' })
            Domains = @([pscustomobject]@{ Domain='corp.example.com'; Server='dc1'; Name='Corp' })
        }
        $data = Get-AdDiscoveryData -InputData $discoveryInput
        $data.Groups[0].Name | Should -Be 'Acme Admins'
        $data.Groups[0].Domain | Should -Be 'corp.example.com'
        $data.VendorUsers[0].Tokens | Should -Contain 'John Smith'
        $data.FailedDomains.Count | Should -Be 0
    }
    It 'records a failed domain and continues' {
        Mock -CommandName Get-ADGroup -MockWith { throw 'server down' }
        $discoveryInput = [pscustomobject]@{
            Users   = @()
            Domains = @([pscustomobject]@{ Domain='dead.example.com'; Server=$null; Name=$null })
        }
        $data = Get-AdDiscoveryData -InputData $discoveryInput
        $data.FailedDomains | Should -Contain 'dead.example.com'
    }
    It 'skips a SamAccountName containing filter-injection characters and warns' {
        $discoveryInput = [pscustomobject]@{
            Users   = @([pscustomobject]@{ SamAccountName="evil') -or (cn=*"; DisplayName='X' })
            Domains = @([pscustomobject]@{ Domain='corp.example.com'; Server='dc1'; Name='Corp' })
        }
        $data = Get-AdDiscoveryData -InputData $discoveryInput
        $data.VendorUsers.Count | Should -Be 0
        ($data.Warnings -join "`n") | Should -Match 'suspicious'
    }
    It 'still resolves vendor users even when group enumeration fails for that domain' {
        Mock -CommandName Get-ADGroup -MockWith { throw 'server down' }
        $inp = [pscustomobject]@{
            Users   = @([pscustomobject]@{ SamAccountName='jsmith'; DisplayName='John Smith' })
            Domains = @([pscustomobject]@{ Domain='corp.example.com'; Server='dc1'; Name='Corp' })
        }
        $data = Get-AdDiscoveryData -InputData $inp
        $data.FailedDomains | Should -Contain 'corp.example.com'
        $data.VendorUsers.Count | Should -Be 1
    }
    It 'resolves two users with the same SamAccountName from different domains independently' {
        Mock -CommandName Get-ADGroup -MockWith { @() }
        Mock -CommandName Get-ADUser -ParameterFilter { $Server -eq 'corp.example.com' } -MockWith {
            [pscustomobject]@{ SamAccountName='jsmith'; DisplayName='John (Corp)'; GivenName='John'; sn='Smith'
                CN='John Smith'; Name='John Smith'; UserPrincipalName='jsmith@corp.example.com'; mail=$null
                DistinguishedName='CN=jsmith,DC=corp,DC=example,DC=com'
                objectSid='S-1-5-21-100-200-300-1001' }
        }
        Mock -CommandName Get-ADUser -ParameterFilter { $Server -eq 'partner.example.com' } -MockWith {
            [pscustomobject]@{ SamAccountName='jsmith'; DisplayName='John (Partner)'; GivenName='John'; sn='Smith'
                CN='John Smith'; Name='John Smith'; UserPrincipalName='jsmith@partner.example.com'; mail=$null
                DistinguishedName='CN=jsmith,DC=partner,DC=example,DC=com'
                objectSid='S-1-5-21-999-888-777-1001' }
        }
        $inp = [pscustomobject]@{
            Users   = @([pscustomobject]@{ SamAccountName='jsmith'; DisplayName='John Smith' })
            Domains = @(
                [pscustomobject]@{ Domain='corp.example.com';    Server='corp.example.com';    Name='Corp' }
                [pscustomobject]@{ Domain='partner.example.com'; Server='partner.example.com'; Name='Partner' }
            )
        }
        $data = Get-AdDiscoveryData -InputData $inp
        $data.VendorUsers.Count | Should -Be 2
    }
    It 'issues one batched LDAP query per domain regardless of user count' {
        Mock -CommandName Get-ADGroup -MockWith { @() }
        Mock -CommandName Get-ADUser  -MockWith { @() }
        $inp = [pscustomobject]@{
            Users   = @(
                [pscustomobject]@{ SamAccountName='adoe';   DisplayName='A Doe' }
                [pscustomobject]@{ SamAccountName='jsmith'; DisplayName='J Smith' }
                [pscustomobject]@{ SamAccountName='kchan';  DisplayName='K Chan' }
            )
            Domains = @(
                [pscustomobject]@{ Domain='corp.example.com';    Server='dc1'; Name='Corp' }
                [pscustomobject]@{ Domain='partner.example.com'; Server='dc2'; Name='Partner' }
            )
        }
        $null = Get-AdDiscoveryData -InputData $inp
        Should -Invoke Get-ADUser -Exactly -Times 2
    }
    It 'builds a sorted OR filter over all valid sams' {
        Mock -CommandName Get-ADGroup -MockWith { @() }
        Mock -CommandName Get-ADUser  -MockWith { @() }
        $inp = [pscustomobject]@{
            Users   = @(
                [pscustomobject]@{ SamAccountName='jsmith'; DisplayName='J Smith' }
                [pscustomobject]@{ SamAccountName='adoe';   DisplayName='A Doe' }
            )
            Domains = @([pscustomobject]@{ Domain='corp.example.com'; Server='dc1'; Name='Corp' })
        }
        $null = Get-AdDiscoveryData -InputData $inp
        Should -Invoke Get-ADUser -Exactly -Times 1 -ParameterFilter {
            $LDAPFilter -eq '(|(sAMAccountName=adoe)(sAMAccountName=jsmith))'
        }
    }
    It 'chunks the batched query above the batch size' {
        Mock -CommandName Get-ADGroup -MockWith { @() }
        Mock -CommandName Get-ADUser  -MockWith { @() }
        $users = 1..201 | ForEach-Object {
            [pscustomobject]@{ SamAccountName=('u{0:d3}' -f $_); DisplayName="U$_" }
        }
        $inp = [pscustomobject]@{
            Users   = @($users)
            Domains = @([pscustomobject]@{ Domain='corp.example.com'; Server='dc1'; Name='Corp' })
        }
        $null = Get-AdDiscoveryData -InputData $inp
        Should -Invoke Get-ADUser -Exactly -Times 2
    }
    It 'warns per domain (not per user) when the batched user lookup fails' {
        Mock -CommandName Get-ADGroup -MockWith { @() }
        Mock -CommandName Get-ADUser  -MockWith { throw 'ldap down' }
        $inp = [pscustomobject]@{
            Users   = @(
                [pscustomobject]@{ SamAccountName='adoe';   DisplayName='A Doe' }
                [pscustomobject]@{ SamAccountName='jsmith'; DisplayName='J Smith' }
            )
            Domains = @([pscustomobject]@{ Domain='corp.example.com'; Server='dc1'; Name='Corp' })
        }
        $data = Get-AdDiscoveryData -InputData $inp
        $data.VendorUsers.Count | Should -Be 0
        @($data.Warnings | Where-Object { $_ -match "User lookup failed in 'corp.example.com'" }).Count |
            Should -Be 1
        # A user-lookup failure is not a failed domain (that is reserved for group enumeration).
        $data.FailedDomains.Count | Should -Be 0
    }
    It 'warns once total (not per domain) for a suspicious SamAccountName' {
        Mock -CommandName Get-ADGroup -MockWith { @() }
        Mock -CommandName Get-ADUser  -MockWith { @() }
        $inp = [pscustomobject]@{
            Users   = @([pscustomobject]@{ SamAccountName="evil') -or (cn=*"; DisplayName='X' })
            Domains = @(
                [pscustomobject]@{ Domain='corp.example.com';    Server='dc1'; Name='Corp' }
                [pscustomobject]@{ Domain='partner.example.com'; Server='dc2'; Name='Partner' }
            )
        }
        $data = Get-AdDiscoveryData -InputData $inp
        @($data.Warnings | Where-Object { $_ -match 'suspicious' }).Count | Should -Be 1
        Should -Invoke Get-ADUser -Exactly -Times 0
    }
}
