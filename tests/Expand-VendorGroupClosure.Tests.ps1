BeforeAll {
    . "$PSScriptRoot/_TestHelpers.ps1"
    function New-Result($name,$dn,$member,$score,$confidence,$known=$false) {
        [pscustomobject]@{ Domain='corp'; Name=$name; DistinguishedName=$dn; Member=@($member)
            Reasons=@(); Score=$score; Confidence=$confidence; IsKnown=$known }
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
        $trusted = New-Result 'IT' 'CN=IT,DC=c' @() 1 'Low'
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
        $trusted = New-Result 'IT' 'CN=IT,DC=c' @() 1 'Low'
        $target  = New-Result 'App Access' 'CN=App Access,DC=c' @() 0 'None'
        $trusted | Add-Member Description ''; $trusted | Add-Member Info ''
        $target | Add-Member Description 'Owner: IT'; $target | Add-Member Info ''

        $out = Expand-VendorGroupClosure -Results @($target, $trusted)
        $t = $out | Where-Object Name -eq 'App Access'
        ($t.Reasons | Where-Object Pattern -eq 'DescriptionGroup').Value | Should -Be 'IT'
        $t.Confidence | Should -Be 'Medium'
    }
    It 'matches a trusted name that begins or ends with punctuation' {
        $trusted = New-Result 'Finance (EMEA)' 'CN=Finance EMEA,DC=c' @() 1 'Low'
        $target  = New-Result 'Ledger Access' 'CN=Ledger Access,DC=c' @() 0 'None'
        $trusted | Add-Member Description ''; $trusted | Add-Member Info ''
        $target | Add-Member Description 'Owner: Finance (EMEA)'; $target | Add-Member Info ''

        $out = Expand-VendorGroupClosure -Results @($target, $trusted)
        $t = $out | Where-Object Name -eq 'Ledger Access'
        ($t.Reasons | Where-Object Pattern -eq 'DescriptionGroup').Value | Should -Be 'Finance (EMEA)'
        $t.Confidence | Should -Be 'Medium'
    }
}
