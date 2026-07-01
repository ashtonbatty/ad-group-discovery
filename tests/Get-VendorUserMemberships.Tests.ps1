BeforeAll { . "$PSScriptRoot/_TestHelpers.ps1" }

Describe 'Get-VendorUserMemberships' {
    BeforeAll {
        $script:users = @(
            [pscustomobject]@{
                SamAccountName='ohaddad'; DisplayName='Omar Haddad'
                Sid='S-1-5-21-9-9-9-1017'; Domain='dmz.globex.net'
                DistinguishedName='CN=Omar Haddad,OU=Vendors,DC=dmz,DC=globex,DC=net'
                MemberOf=@('CN=Northwind RW,OU=Groups,DC=dmz,DC=globex,DC=net')
            }
        )
        # A cross-domain group in corp where ohaddad is present as a foreign security principal.
        $script:groups = @(
            [pscustomobject]@{
                Domain='corp.globex.com'; Name='NWT Application Owners'
                DistinguishedName='CN=NWT Application Owners,OU=Northwind,OU=Vendors,DC=corp,DC=globex,DC=com'
                Member=@('CN=S-1-5-21-9-9-9-1017,CN=ForeignSecurityPrincipals,DC=corp,DC=globex,DC=com')
            }
        )
    }

    It 'emits a home-domain memberOf row with domain and name derived from the DN' {
        $rows = @(Get-VendorUserMemberships -VendorUsers $script:users -Groups @())
        $homeMembership = $rows | Where-Object GroupName -eq 'Northwind RW'
        $homeMembership.UserDomain  | Should -Be 'dmz.globex.net'
        $homeMembership.GroupDomain | Should -Be 'dmz.globex.net'
        $homeMembership.UserSamAccountName | Should -Be 'ohaddad'
    }

    It 'emits a cross-domain row from the discovered-group FSP member side' {
        $rows = @(Get-VendorUserMemberships -VendorUsers $script:users -Groups $script:groups)
        $cross = $rows | Where-Object GroupName -eq 'NWT Application Owners'
        $cross.GroupDomain | Should -Be 'corp.globex.com'
        $cross.UserDomain  | Should -Be 'dmz.globex.net'
    }

    It 'dedups a group seen from both sources, preferring the discovered name' {
        $u = [pscustomobject]@{
            SamAccountName='jbrooks'; DisplayName='Jacob Brooks'
            Sid='S-1-5-21-9-9-9-1001'; Domain='corp.globex.com'
            DistinguishedName='CN=Jacob Brooks,OU=Vendors,DC=corp,DC=globex,DC=com'
            MemberOf=@('CN=NWT Application Owners,OU=Northwind,OU=Vendors,DC=corp,DC=globex,DC=com')
        }
        $g = [pscustomobject]@{
            Domain='corp.globex.com'; Name='NWT Application Owners'
            DistinguishedName='CN=NWT Application Owners,OU=Northwind,OU=Vendors,DC=corp,DC=globex,DC=com'
            Member=@('CN=Jacob Brooks,OU=Vendors,DC=corp,DC=globex,DC=com')
        }
        $rows = @(Get-VendorUserMemberships -VendorUsers @($u) -Groups @($g))
        @($rows | Where-Object GroupName -eq 'NWT Application Owners').Count | Should -Be 1
    }

    It 'returns nothing for a user with no memberships' {
        $u = [pscustomobject]@{ SamAccountName='x'; DisplayName='X'; Sid='S-1-5-21-0-0-0-1'
            Domain='corp.globex.com'; DistinguishedName='CN=X,DC=corp,DC=globex,DC=com'; MemberOf=@() }
        @(Get-VendorUserMemberships -VendorUsers @($u) -Groups @()).Count | Should -Be 0
    }
}
