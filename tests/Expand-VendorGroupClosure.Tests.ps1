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
}
