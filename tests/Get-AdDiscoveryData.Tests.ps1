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
        $data.VendorUsers[0].Tokens | Should -Contain 'jsmith'
        $data.VendorUsers[0].Tokens | Should -Contain 'jsmith@vendor.com'
        $data.VendorUsers[0].Tokens | Should -Not -Contain 'John Smith'
        $data.FailedDomains.Count | Should -Be 0
    }
    It 'records a failed domain and continues' {
        Mock -CommandName Get-ADGroup -MockWith { throw 'server down' }
        $discoveryInput = [pscustomobject]@{
            Users       = @()
            Keywords    = @('Acme')
            KnownGroups = @()
            Domains     = @([pscustomobject]@{ Domain='dead.example.com'; Server=$null; Name=$null })
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
    It 'adds the security-group LDAP bit filter when SecurityGroupsOnly is requested' {
        Mock -CommandName Get-ADGroup -MockWith { @() }
        Mock -CommandName Get-ADOrganizationalUnit -MockWith { @() }
        Mock -CommandName Get-ADUser -MockWith { @() }
        $inp = [pscustomobject]@{
            Users       = @()
            Keywords    = @('Acme')
            KnownGroups = @()
            Domains     = @([pscustomobject]@{ Domain='corp.example.com'; Server='dc1'; Name='Corp' })
        }
        $null = Get-AdDiscoveryData -InputData $inp -SecurityGroupsOnly
        Should -Invoke Get-ADGroup -Exactly -Times 1 -ParameterFilter {
            $LDAPFilter -match 'groupType:1\.2\.840\.113556\.1\.4\.803:=2147483648'
        }
    }
    It 'does not add the security-group LDAP bit filter by default' {
        Mock -CommandName Get-ADGroup -MockWith { @() }
        Mock -CommandName Get-ADOrganizationalUnit -MockWith { @() }
        Mock -CommandName Get-ADUser -MockWith { @() }
        $inp = [pscustomobject]@{
            Users       = @()
            Keywords    = @('Acme')
            KnownGroups = @()
            Domains     = @([pscustomobject]@{ Domain='corp.example.com'; Server='dc1'; Name='Corp' })
        }
        $null = Get-AdDiscoveryData -InputData $inp
        Should -Invoke Get-ADGroup -Exactly -Times 1 -ParameterFilter {
            $LDAPFilter -match 'Acme' -and
            $LDAPFilter -notmatch 'groupType:1\.2\.840\.113556\.1\.4\.803:=2147483648'
        }
    }
    It 'uses lightweight group properties for candidate searches' {
        Mock -CommandName Get-ADGroup -MockWith { @() }
        Mock -CommandName Get-ADOrganizationalUnit -MockWith { @() }
        Mock -CommandName Get-ADUser -MockWith { @() }
        $inp = [pscustomobject]@{
            Users       = @()
            Keywords    = @('Acme')
            KnownGroups = @()
            Domains     = @([pscustomobject]@{ Domain='corp.example.com'; Server='dc1'; Name='Corp' })
        }
        $null = Get-AdDiscoveryData -InputData $inp
        Should -Invoke Get-ADGroup -Exactly -Times 1 -ParameterFilter {
            $LDAPFilter -match 'Acme' -and
            $Properties -contains 'description' -and
            $Properties -notcontains 'member' -and
            $Properties -notcontains 'memberOf'
        }
    }
    It 'discovers groups by direct vendor membership and hydrates only candidates' {
        $groupDn = 'CN=Acme Admins,OU=Groups,DC=corp,DC=example,DC=com'
        $userDn = 'CN=John Smith,OU=Vendor,DC=corp,DC=example,DC=com'
        Mock -CommandName Get-ADUser -MockWith {
            [pscustomobject]@{ SamAccountName='jsmith'; DisplayName='John Smith'; GivenName='John'; sn='Smith'
                CN='John Smith'; Name='John Smith'; UserPrincipalName='jsmith@vendor.com'; mail='jsmith@vendor.com'
                DistinguishedName=$userDn; objectSid='S-1-5-21-1-2-3-1001'; memberOf=@() }
        }
        Mock -CommandName Get-ADGroup -ParameterFilter { $LDAPFilter -like '*member=CN=John Smith*' } -MockWith {
            [pscustomobject]@{ Name='Acme Admins'; DistinguishedName=$groupDn
                description=''; info=''; managedBy=''; GroupScope='Global'; GroupCategory='Security' }
        }
        Mock -CommandName Get-ADGroup -ParameterFilter { $Identity -eq $groupDn } -MockWith {
            [pscustomobject]@{ Name='Acme Admins'; DistinguishedName=$groupDn
                description=''; info=''; managedBy=''; member=@($userDn); memberof=@()
                GroupScope='Global'; GroupCategory='Security'; mail=$null; adminCount=$null
                whenCreated=$null; whenChanged=$null }
        }
        Mock -CommandName Get-ADGroup -MockWith { @() }
        $inp = [pscustomobject]@{
            Users       = @([pscustomobject]@{ SamAccountName='jsmith'; DisplayName='John Smith' })
            Keywords    = @()
            KnownGroups = @()
            Domains     = @([pscustomobject]@{ Domain='corp.example.com'; Server='dc1'; Name='Corp' })
        }
        $data = Get-AdDiscoveryData -InputData $inp
        $data.Groups.Name | Should -Contain 'Acme Admins'
        $data.Groups[0].Member | Should -Contain $userDn
    }
    It 'hydrates direct member directory objects for report shaping' {
        $groupDn = 'CN=Acme Admins,OU=Groups,DC=corp,DC=example,DC=com'
        $memberDn = 'CN=Bob Jones,OU=Staff,DC=corp,DC=example,DC=com'
        Mock -CommandName Get-ADUser -MockWith { @() }
        Mock -CommandName Get-ADOrganizationalUnit -MockWith { @() }
        Mock -CommandName Get-ADGroup -ParameterFilter { $LDAPFilter -like '*name=*Acme**' } -MockWith {
            [pscustomobject]@{ Name='Acme Admins'; DistinguishedName=$groupDn
                description=''; info=''; managedBy=''; GroupScope='Global'; GroupCategory='Security' }
        }
        Mock -CommandName Get-ADGroup -ParameterFilter { $Identity -eq $groupDn } -MockWith {
            [pscustomobject]@{ Name='Acme Admins'; DistinguishedName=$groupDn
                description=''; info=''; managedBy=''; member=@($memberDn); memberof=@()
                GroupScope='Global'; GroupCategory='Security'; mail=$null; adminCount=$null
                whenCreated=$null; whenChanged=$null }
        }
        Mock -CommandName Get-ADObject -ParameterFilter { $Identity -eq $memberDn } -MockWith {
            [pscustomobject]@{ DistinguishedName=$memberDn; sAMAccountName='bjones'
                displayName='Bob Jones'; name='Bob Jones'; objectClass=@('top','person','user') }
        }
        Mock -CommandName Get-ADGroup -MockWith { @() }
        $inp = [pscustomobject]@{
            Users       = @()
            Keywords    = @('Acme')
            KnownGroups = @()
            Domains     = @([pscustomobject]@{ Domain='corp.example.com'; Server='dc1'; Name='Corp' })
        }
        $data = Get-AdDiscoveryData -InputData $inp
        $memberObject = $data.Groups[0].MemberDirectoryObjects[0]
        $memberObject.SamAccountName | Should -Be 'bjones'
        $memberObject.DisplayName | Should -Be 'Bob Jones'
        $memberObject.ObjectClass | Should -Be 'user'
        Should -Invoke Get-ADObject -Exactly -Times 1 -ParameterFilter { $Identity -eq $memberDn }
    }
    It 'discovers groups by keyword LDAP search' {
        $groupDn = 'CN=Acme Operators,OU=Groups,DC=corp,DC=example,DC=com'
        Mock -CommandName Get-ADUser -MockWith { @() }
        Mock -CommandName Get-ADOrganizationalUnit -MockWith { @() }
        Mock -CommandName Get-ADGroup -ParameterFilter { $LDAPFilter -like '*name=*Acme**' } -MockWith {
            [pscustomobject]@{ Name='Acme Operators'; DistinguishedName=$groupDn
                description=''; info=''; managedBy=''; GroupScope='Global'; GroupCategory='Security' }
        }
        Mock -CommandName Get-ADGroup -ParameterFilter { $Identity -eq $groupDn } -MockWith {
            [pscustomobject]@{ Name='Acme Operators'; DistinguishedName=$groupDn
                description=''; info=''; managedBy=''; member=@(); memberof=@()
                GroupScope='Global'; GroupCategory='Security'; mail=$null; adminCount=$null
                whenCreated=$null; whenChanged=$null }
        }
        Mock -CommandName Get-ADGroup -MockWith { @() }
        $inp = [pscustomobject]@{
            Users       = @()
            Keywords    = @('Acme')
            KnownGroups = @()
            Domains     = @([pscustomobject]@{ Domain='corp.example.com'; Server='dc1'; Name='Corp' })
        }
        (Get-AdDiscoveryData -InputData $inp).Groups.Name | Should -Contain 'Acme Operators'
    }
    It 'discovers known groups by exact name lookup' {
        $groupDn = 'CN=Project Atlas Team,OU=Groups,DC=corp,DC=example,DC=com'
        Mock -CommandName Get-ADUser -MockWith { @() }
        Mock -CommandName Get-ADGroup -ParameterFilter { $LDAPFilter -like '*name=Project Atlas Team*' } -MockWith {
            [pscustomobject]@{ Name='Project Atlas Team'; DistinguishedName=$groupDn
                description=''; info=''; managedBy=''; GroupScope='Global'; GroupCategory='Security' }
        }
        Mock -CommandName Get-ADGroup -ParameterFilter { $Identity -eq $groupDn } -MockWith {
            [pscustomobject]@{ Name='Project Atlas Team'; DistinguishedName=$groupDn
                description=''; info=''; managedBy=''; member=@(); memberof=@()
                GroupScope='Global'; GroupCategory='Security'; mail=$null; adminCount=$null
                whenCreated=$null; whenChanged=$null }
        }
        Mock -CommandName Get-ADGroup -MockWith { @() }
        $inp = [pscustomobject]@{
            Users       = @()
            Keywords    = @()
            KnownGroups = @([pscustomobject]@{ Domain='corp.example.com'; Identity='Project Atlas Team' })
            Domains     = @([pscustomobject]@{ Domain='corp.example.com'; Server='dc1'; Name='Corp' })
        }
        (Get-AdDiscoveryData -InputData $inp).Groups.Name | Should -Contain 'Project Atlas Team'
    }
    It 'discovers groups under keyword-matched OUs' {
        $ouDn = 'OU=Acme,DC=corp,DC=example,DC=com'
        $groupDn = 'CN=Access,OU=Acme,DC=corp,DC=example,DC=com'
        Mock -CommandName Get-ADUser -MockWith { @() }
        Mock -CommandName Get-ADOrganizationalUnit -MockWith {
            [pscustomobject]@{ Name='Acme'; DistinguishedName=$ouDn }
        }
        Mock -CommandName Get-ADGroup -ParameterFilter { $SearchBase -eq $ouDn } -MockWith {
            [pscustomobject]@{ Name='Access'; DistinguishedName=$groupDn
                description=''; info=''; managedBy=''; GroupScope='Global'; GroupCategory='Security' }
        }
        Mock -CommandName Get-ADGroup -ParameterFilter { $Identity -eq $groupDn } -MockWith {
            [pscustomobject]@{ Name='Access'; DistinguishedName=$groupDn
                description=''; info=''; managedBy=''; member=@(); memberof=@()
                GroupScope='Global'; GroupCategory='Security'; mail=$null; adminCount=$null
                whenCreated=$null; whenChanged=$null }
        }
        Mock -CommandName Get-ADGroup -MockWith { @() }
        $inp = [pscustomobject]@{
            Users       = @()
            Keywords    = @('Acme')
            KnownGroups = @()
            Domains     = @([pscustomobject]@{ Domain='corp.example.com'; Server='dc1'; Name='Corp' })
        }
        (Get-AdDiscoveryData -InputData $inp).Groups.Name | Should -Contain 'Access'
    }
    It 'discovers nested parent groups through targeted parent lookup' {
        $userDn = 'CN=John Smith,OU=Vendor,DC=corp,DC=example,DC=com'
        $childDn = 'CN=Acme Admins,OU=Groups,DC=corp,DC=example,DC=com'
        $parentDn = 'CN=Global Stewards,OU=Groups,DC=corp,DC=example,DC=com'
        Mock -CommandName Get-ADUser -MockWith {
            [pscustomobject]@{ SamAccountName='jsmith'; DisplayName='John Smith'; GivenName='John'; sn='Smith'
                CN='John Smith'; Name='John Smith'; UserPrincipalName='jsmith@vendor.com'; mail=$null
                DistinguishedName=$userDn; objectSid='S-1-5-21-1-2-3-1001'; memberOf=@() }
        }
        Mock -CommandName Get-ADGroup -ParameterFilter { $LDAPFilter -like "*member=$userDn*" } -MockWith {
            [pscustomobject]@{ Name='Acme Admins'; DistinguishedName=$childDn
                description=''; info=''; managedBy=''; GroupScope='Global'; GroupCategory='Security' }
        }
        Mock -CommandName Get-ADGroup -ParameterFilter { $LDAPFilter -like "*member=$childDn*" } -MockWith {
            [pscustomobject]@{ Name='Global Stewards'; DistinguishedName=$parentDn
                description=''; info=''; managedBy=''; GroupScope='Global'; GroupCategory='Security' }
        }
        Mock -CommandName Get-ADGroup -ParameterFilter { $Identity -eq $childDn } -MockWith {
            [pscustomobject]@{ Name='Acme Admins'; DistinguishedName=$childDn
                description=''; info=''; managedBy=''; member=@($userDn); memberof=@($parentDn)
                GroupScope='Global'; GroupCategory='Security'; mail=$null; adminCount=$null
                whenCreated=$null; whenChanged=$null }
        }
        Mock -CommandName Get-ADGroup -ParameterFilter { $Identity -eq $parentDn } -MockWith {
            [pscustomobject]@{ Name='Global Stewards'; DistinguishedName=$parentDn
                description=''; info=''; managedBy=''; member=@($childDn); memberof=@()
                GroupScope='Global'; GroupCategory='Security'; mail=$null; adminCount=$null
                whenCreated=$null; whenChanged=$null }
        }
        Mock -CommandName Get-ADGroup -MockWith { @() }
        $inp = [pscustomobject]@{
            Users       = @([pscustomobject]@{ SamAccountName='jsmith'; DisplayName='John Smith' })
            Keywords    = @()
            KnownGroups = @()
            Domains     = @([pscustomobject]@{ Domain='corp.example.com'; Server='dc1'; Name='Corp' })
        }
        (Get-AdDiscoveryData -InputData $inp).Groups.Name | Should -Contain 'Global Stewards'
    }
    It 'discovers description-owned groups transitively and queries each trusted name once per domain' {
        $trustedDn = 'CN=Trusted Owners,OU=Groups,DC=corp,DC=example,DC=com'
        $appDn = 'CN=Application Access,OU=Groups,DC=corp,DC=example,DC=com'
        $portalDn = 'CN=Portal Access,OU=Groups,DC=corp,DC=example,DC=com'
        Mock -CommandName Get-ADUser -MockWith { @() }
        Mock -CommandName Get-ADGroup -ParameterFilter { $LDAPFilter -like '*name=Trusted Owners*' } -MockWith {
            [pscustomobject]@{ Name='Trusted Owners'; DistinguishedName=$trustedDn
                description=''; info=''; managedBy=''; GroupScope='Global'; GroupCategory='Security' }
        }
        Mock -CommandName Get-ADGroup -ParameterFilter { $LDAPFilter -like '*description=*Trusted Owners**' } -MockWith {
            [pscustomobject]@{ Name='Application Access'; DistinguishedName=$appDn
                description='Owner: Trusted Owners'; info=''; managedBy=''; GroupScope='Global'; GroupCategory='Security' }
        }
        Mock -CommandName Get-ADGroup -ParameterFilter { $LDAPFilter -like '*description=*Application Access**' } -MockWith {
            [pscustomobject]@{ Name='Portal Access'; DistinguishedName=$portalDn
                description='Owner: Application Access'; info=''; managedBy=''; GroupScope='Global'; GroupCategory='Security' }
        }
        Mock -CommandName Get-ADGroup -ParameterFilter { $Identity -eq $trustedDn } -MockWith {
            [pscustomobject]@{ Name='Trusted Owners'; DistinguishedName=$trustedDn
                description=''; info=''; managedBy=''; member=@(); memberof=@()
                GroupScope='Global'; GroupCategory='Security'; mail=$null; adminCount=$null
                whenCreated=$null; whenChanged=$null }
        }
        Mock -CommandName Get-ADGroup -ParameterFilter { $Identity -eq $appDn } -MockWith {
            [pscustomobject]@{ Name='Application Access'; DistinguishedName=$appDn
                description='Owner: Trusted Owners'; info=''; managedBy=''; member=@(); memberof=@()
                GroupScope='Global'; GroupCategory='Security'; mail=$null; adminCount=$null
                whenCreated=$null; whenChanged=$null }
        }
        Mock -CommandName Get-ADGroup -ParameterFilter { $Identity -eq $portalDn } -MockWith {
            [pscustomobject]@{ Name='Portal Access'; DistinguishedName=$portalDn
                description='Owner: Application Access'; info=''; managedBy=''; member=@(); memberof=@()
                GroupScope='Global'; GroupCategory='Security'; mail=$null; adminCount=$null
                whenCreated=$null; whenChanged=$null }
        }
        Mock -CommandName Get-ADGroup -MockWith { @() }
        $inp = [pscustomobject]@{
            Users       = @()
            Keywords    = @()
            KnownGroups = @(
                [pscustomobject]@{ Domain='corp.example.com'; Identity='Trusted Owners' }
                [pscustomobject]@{ Domain='corp.example.com'; Identity='TRUSTED OWNERS' }
            )
            Domains = @([pscustomobject]@{ Domain='corp.example.com'; Server='dc1'; Name='Corp' })
        }

        $data = Get-AdDiscoveryData -InputData $inp
        $data.Groups.Name | Should -Contain 'Application Access'
        $data.Groups.Name | Should -Contain 'Portal Access'
        Should -Invoke Get-ADGroup -Exactly -Times 1 -ParameterFilter {
            $LDAPFilter -like '*description=*Trusted Owners**'
        }
        Should -Invoke Get-ADGroup -Exactly -Times 1 -ParameterFilter {
            $LDAPFilter -like '*description=*Application Access**'
        }
    }
    It 'maintains the trusted-name query ledger independently for each domain' {
        Mock -CommandName Get-ADUser -MockWith { @() }
        Mock -CommandName Get-ADGroup -ParameterFilter { $LDAPFilter -like '*name=Trusted Owners*' } -MockWith {
            $domainDn = if ($Server -eq 'dc1') { 'DC=corp,DC=example,DC=com' } else { 'DC=partner,DC=example,DC=com' }
            [pscustomobject]@{ Name='Trusted Owners'; DistinguishedName="CN=Trusted Owners,OU=Groups,$domainDn"
                description=''; info=''; managedBy=''; GroupScope='Global'; GroupCategory='Security' }
        }
        Mock -CommandName Get-ADGroup -ParameterFilter { $Identity -like 'CN=Trusted Owners,*' } -MockWith {
            [pscustomobject]@{ Name='Trusted Owners'; DistinguishedName=$Identity
                description=''; info=''; managedBy=''; member=@(); memberof=@()
                GroupScope='Global'; GroupCategory='Security'; mail=$null; adminCount=$null
                whenCreated=$null; whenChanged=$null }
        }
        Mock -CommandName Get-ADGroup -MockWith { @() }
        $inp = [pscustomobject]@{
            Users       = @()
            Keywords    = @()
            KnownGroups = @(
                [pscustomobject]@{ Domain='corp.example.com'; Identity='Trusted Owners' }
                [pscustomobject]@{ Domain='partner.example.com'; Identity='Trusted Owners' }
            )
            Domains = @(
                [pscustomobject]@{ Domain='corp.example.com'; Server='dc1'; Name='Corp' }
                [pscustomobject]@{ Domain='partner.example.com'; Server='dc2'; Name='Partner' }
            )
        }

        $null = Get-AdDiscoveryData -InputData $inp
        Should -Invoke Get-ADGroup -Exactly -Times 1 -ParameterFilter {
            $Server -eq 'dc1' -and $LDAPFilter -like '*description=*Trusted Owners**'
        }
        Should -Invoke Get-ADGroup -Exactly -Times 1 -ParameterFilter {
            $Server -eq 'dc2' -and $LDAPFilter -like '*description=*Trusted Owners**'
        }
    }
    It 'does not issue a trusted-name description search for short (<4 char) names' {
        $itDn = 'CN=IT,OU=Groups,DC=corp,DC=example,DC=com'
        Mock -CommandName Get-ADUser -MockWith { @() }
        Mock -CommandName Get-ADGroup -ParameterFilter { $LDAPFilter -like '*name=IT*' } -MockWith {
            [pscustomobject]@{ Name='IT'; DistinguishedName=$itDn
                description=''; info=''; managedBy=''; GroupScope='Global'; GroupCategory='Security' }
        }
        Mock -CommandName Get-ADGroup -ParameterFilter { $Identity -eq $itDn } -MockWith {
            [pscustomobject]@{ Name='IT'; DistinguishedName=$itDn
                description=''; info=''; managedBy=''; member=@(); memberof=@()
                GroupScope='Global'; GroupCategory='Security'; mail=$null; adminCount=$null
                whenCreated=$null; whenChanged=$null }
        }
        Mock -CommandName Get-ADGroup -MockWith { @() }
        $inp = [pscustomobject]@{
            Users       = @()
            Keywords    = @()
            KnownGroups = @([pscustomobject]@{ Domain='corp.example.com'; Identity='IT' })
            Domains     = @([pscustomobject]@{ Domain='corp.example.com'; Server='dc1'; Name='Corp' })
        }

        $null = Get-AdDiscoveryData -InputData $inp
        Should -Invoke Get-ADGroup -Exactly -Times 0 -ParameterFilter {
            $LDAPFilter -like '*description=*IT**'
        }
    }
}
