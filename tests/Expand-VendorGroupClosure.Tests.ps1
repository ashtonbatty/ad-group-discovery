BeforeAll {
    . "$PSScriptRoot/_TestHelpers.ps1"
    function New-Result($name,$dn,$member,$score,$confidence,$known=$false) {
        [pscustomobject]@{ Domain='corp'; Name=$name; DistinguishedName=$dn; Member=@($member)
            Reasons=@(); Score=$score; Confidence=$confidence; IsKnown=$known }
    }
    function New-Reason($pattern,$value) { [pscustomobject]@{ Pattern=$pattern; Value=$value } }
    # A Low-confidence group that seeds description matching: its only signal is
    # vendor membership, but the membership is exclusively vendor users.
    function New-VendorOnlyResult($name,$dn) {
        $r = New-Result $name $dn @() 1 'Low'
        $r.Reasons = @(New-Reason 'MemberVendorUser' 'John Smith')
        $r | Add-Member AllMembersVendor $true
        $r
    }
}

Describe 'Expand-VendorGroupClosure' {
    It 'promotes a parent group that contains a confirmed vendor group' {
        # child is High (score 3, confirmed vendor group); parent has child as a member, no direct signal
        $child  = New-Result 'Acme Admins' 'CN=Acme Admins,DC=c' @() 3 'High'
        $parent = New-Result 'App Owners'  'CN=App Owners,DC=c'  'CN=Acme Admins,DC=c' 0 'None'
        $out = Expand-VendorGroupClosure -Results @($parent,$child)
        $p = $out | Where-Object Name -eq 'App Owners'
        ($p.Reasons | Where-Object Pattern -eq 'NestedVendorGroup').Value | Should -Be 'Acme Admins'
        $p.Confidence | Should -Be 'Medium'
    }
    It 'propagates transitively (grandparent picks up promoted parent)' {
        $child  = New-Result 'Acme Admins'  'CN=Acme Admins,DC=c'  @() 3 'High'
        $parent = New-Result 'App Owners'    'CN=App Owners,DC=c'   'CN=Acme Admins,DC=c' 0 'None'
        $gp     = New-Result 'Super Owners'  'CN=Super Owners,DC=c' 'CN=App Owners,DC=c'  0 'None'
        $out = Expand-VendorGroupClosure -Results @($gp,$parent,$child)
        ($out | Where-Object Name -eq 'Super Owners').Confidence | Should -Be 'Medium'
    }
    It 'terminates on a membership cycle without error' {
        $a = New-Result 'A' 'CN=A,DC=c' 'CN=B,DC=c' 2 'Medium'
        $b = New-Result 'B' 'CN=B,DC=c' 'CN=A,DC=c' 2 'Medium'
        { Expand-VendorGroupClosure -Results @($a,$b) -MaxIterations 25 } | Should -Not -Throw
    }
    It 'adds a NestedVendorGroup reason for each distinct child even when children share the same Name' {
        $child1 = [pscustomobject]@{ Domain='corp';    Name='Acme Admins'; DistinguishedName='CN=Acme Admins,DC=corp,DC=c'
                                      Member=@(); Reasons=@(); Score=3; Confidence='High'; IsKnown=$false }
        $child2 = [pscustomobject]@{ Domain='partner'; Name='Acme Admins'; DistinguishedName='CN=Acme Admins,DC=partner,DC=c'
                                      Member=@(); Reasons=@(); Score=3; Confidence='High'; IsKnown=$false }
        $parent = [pscustomobject]@{ Domain='corp'; Name='App Owners'; DistinguishedName='CN=App Owners,DC=c'
                                      Member=@('CN=Acme Admins,DC=corp,DC=c','CN=Acme Admins,DC=partner,DC=c')
                                      Reasons=@(); Score=0; Confidence='None'; IsKnown=$false }
        $out = Expand-VendorGroupClosure -Results @($parent, $child1, $child2)
        $p = $out | Where-Object Name -eq 'App Owners'
        ($p.Reasons | Where-Object Pattern -eq 'NestedVendorGroup').Count | Should -Be 2
    }
    It 'promotes a group whose description names a trusted group' {
        $trusted = New-Result 'Acme Admins' 'CN=Acme Admins,DC=c' @() 3 'High'
        $trusted.Reasons = @(New-Reason 'NameKeyword' 'acme')
        $target = New-Result 'Application Owners' 'CN=Application Owners,DC=c' @() 0 'None'
        $trusted | Add-Member Description ''
        $trusted | Add-Member Info ''
        $target | Add-Member Description 'Owner: Acme Admins'
        $target | Add-Member Info ''

        $out = Expand-VendorGroupClosure -Results @($target, $trusted)
        $reason = ($out | Where-Object Name -eq 'Application Owners').Reasons |
            Where-Object Pattern -eq 'DescriptionGroup'
        $reason.Value | Should -Be 'Acme Admins'
        ($out | Where-Object Name -eq 'Application Owners').Confidence | Should -Be 'Medium'
    }
    It 'propagates description group trust transitively without self-matching' {
        $a = New-Result 'A Group' 'CN=A Group,DC=c' @() 3 'High'
        $a.Reasons = @(New-Reason 'NameKeyword' 'a group')
        $b = New-Result 'B Group' 'CN=B Group,DC=c' @() 0 'None'
        $c = New-Result 'C Group' 'CN=C Group,DC=c' @() 0 'None'
        $a | Add-Member Description 'A Group'; $a | Add-Member Info ''
        $b | Add-Member Description 'Owner: A Group'; $b | Add-Member Info ''
        $c | Add-Member Description 'Owner: B Group'; $c | Add-Member Info ''

        $out = Expand-VendorGroupClosure -Results @($c, $b, $a)
        @($out | Where-Object Name -eq 'A Group').Reasons.Pattern | Should -Not -Contain 'DescriptionGroup'
        ($out | Where-Object Name -eq 'B Group').Confidence | Should -Be 'Medium'
        ($out | Where-Object Name -eq 'C Group').Confidence | Should -Be 'Medium'
    }
    It 'matches a trusted name only as a whole word, not as a substring' {
        $trusted = New-VendorOnlyResult 'IT' 'CN=IT,DC=c'
        $target  = New-Result 'Security Team' 'CN=Security Team,DC=c' @() 0 'None'
        $trusted | Add-Member Description ''; $trusted | Add-Member Info ''
        # "security" and "monitoring" both contain "it" as a substring.
        $target | Add-Member Description 'Handles all security monitoring'; $target | Add-Member Info ''

        $out = Expand-VendorGroupClosure -Results @($target, $trusted)
        $t = $out | Where-Object Name -eq 'Security Team'
        @($t.Reasons | Where-Object Pattern -eq 'DescriptionGroup').Count | Should -Be 0
        $t.Confidence | Should -Be 'None'
    }
    It 'matches a short trusted name when it appears as a whole word' {
        $trusted = New-VendorOnlyResult 'IT' 'CN=IT,DC=c'
        $target  = New-Result 'App Access' 'CN=App Access,DC=c' @() 0 'None'
        $trusted | Add-Member Description ''; $trusted | Add-Member Info ''
        $target | Add-Member Description 'Owner: IT'; $target | Add-Member Info ''

        $out = Expand-VendorGroupClosure -Results @($target, $trusted)
        $t = $out | Where-Object Name -eq 'App Access'
        ($t.Reasons | Where-Object Pattern -eq 'DescriptionGroup').Value | Should -Be 'IT'
        $t.Confidence | Should -Be 'Medium'
    }
    It 'does not trust the name of a group whose only signal is an incidental vendor membership' {
        # A vendor account sitting in Domain Admins (Low via one MemberVendorUser)
        # must not make "Domain Admins" a trusted description token: that would
        # promote every unrelated group whose description mentions it.
        $da = New-Result 'Domain Admins' 'CN=Domain Admins,CN=Users,DC=c' @() 1 'Low'
        $da.Reasons = @(New-Reason 'MemberVendorUser' 'John Smith')
        $da | Add-Member AllMembersVendor $false
        $da | Add-Member Description ''; $da | Add-Member Info ''
        $target = New-Result 'SQL Backup Operators' 'CN=SQL Backup Operators,DC=c' @() 0 'None'
        $target | Add-Member Description 'Escalations handled by Domain Admins'; $target | Add-Member Info ''

        $out = Expand-VendorGroupClosure -Results @($target, $da)
        $t = $out | Where-Object Name -eq 'SQL Backup Operators'
        @($t.Reasons | Where-Object Pattern -eq 'DescriptionGroup').Count | Should -Be 0
        $t.Confidence | Should -Be 'None'
    }
    It 'does not trust a member-only group name even when multiple memberships reach Medium' {
        $g = New-Result 'Remote Desktop Users' 'CN=Remote Desktop Users,DC=c' @() 2 'Medium'
        $g.Reasons = @((New-Reason 'MemberVendorUser' 'John Smith'), (New-Reason 'MemberVendorUser' 'Jane Doe'))
        $g | Add-Member AllMembersVendor $false
        $g | Add-Member Description ''; $g | Add-Member Info ''
        $target = New-Result 'Jump Host Access' 'CN=Jump Host Access,DC=c' @() 0 'None'
        $target | Add-Member Description 'Members mirror Remote Desktop Users'; $target | Add-Member Info ''

        $out = Expand-VendorGroupClosure -Results @($target, $g)
        $t = $out | Where-Object Name -eq 'Jump Host Access'
        @($t.Reasons | Where-Object Pattern -eq 'DescriptionGroup').Count | Should -Be 0
        $t.Confidence | Should -Be 'None'
    }
    It 'trusts a member-only group name when every member is a vendor user' {
        $g = New-VendorOnlyResult 'Acme Support Staff' 'CN=Acme Support Staff,DC=c'
        $g | Add-Member Description ''; $g | Add-Member Info ''
        $target = New-Result 'Warehouse App RW' 'CN=Warehouse App RW,DC=c' @() 0 'None'
        $target | Add-Member Description 'Access managed by Acme Support Staff'; $target | Add-Member Info ''

        $out = Expand-VendorGroupClosure -Results @($target, $g)
        $t = $out | Where-Object Name -eq 'Warehouse App RW'
        ($t.Reasons | Where-Object Pattern -eq 'DescriptionGroup').Value | Should -Be 'Acme Support Staff'
        $t.Confidence | Should -Be 'Medium'
    }
    It 'trusts a member-only group name when the group is in known.csv' {
        $g = New-Result 'Acme Legacy Ops' 'CN=Acme Legacy Ops,DC=c' @() 1 'Low' $true
        $g.Reasons = @(New-Reason 'MemberVendorUser' 'John Smith')
        $g | Add-Member AllMembersVendor $false
        $g | Add-Member Description ''; $g | Add-Member Info ''
        $target = New-Result 'Dock Scheduler Users' 'CN=Dock Scheduler Users,DC=c' @() 0 'None'
        $target | Add-Member Description 'Owner: Acme Legacy Ops'; $target | Add-Member Info ''

        $out = Expand-VendorGroupClosure -Results @($target, $g)
        ($out | Where-Object Name -eq 'Dock Scheduler Users').Confidence | Should -Be 'Medium'
    }
    It 'matches a trusted name that begins or ends with punctuation' {
        $trusted = New-VendorOnlyResult 'Finance (EMEA)' 'CN=Finance EMEA,DC=c'
        $target  = New-Result 'Ledger Access' 'CN=Ledger Access,DC=c' @() 0 'None'
        $trusted | Add-Member Description ''; $trusted | Add-Member Info ''
        $target | Add-Member Description 'Owner: Finance (EMEA)'; $target | Add-Member Info ''

        $out = Expand-VendorGroupClosure -Results @($target, $trusted)
        $t = $out | Where-Object Name -eq 'Ledger Access'
        ($t.Reasons | Where-Object Pattern -eq 'DescriptionGroup').Value | Should -Be 'Finance (EMEA)'
        $t.Confidence | Should -Be 'Medium'
    }
    It 'does not promote description mentions of a parent trusted only via nested containment' {
        $child = New-Result 'Acme Ops' 'CN=Acme Ops,DC=c' @() 3 'High'
        $child.Reasons = @(New-Reason 'Owner' 'jsmith')
        $parent = New-Result 'Administrators' 'CN=Administrators,CN=Builtin,DC=c' @('CN=Acme Ops,DC=c') 0 'None'
        $decoy = New-Result 'Print Ops' 'CN=Print Ops,DC=c' @() 0 'None'
        foreach ($r in @($child, $parent, $decoy)) {
            $r | Add-Member Description ''; $r | Add-Member Info ''
        }
        $decoy.Description = 'Administrators of the print estate.'
        $out = Expand-VendorGroupClosure -Results @($child, $parent, $decoy)
        ($out | Where-Object Name -eq 'Administrators').Confidence | Should -Be 'Medium'
        ($out | Where-Object Name -eq 'Print Ops').Confidence | Should -Be 'None'
    }
}
