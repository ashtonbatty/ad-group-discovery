BeforeAll {
    . "$PSScriptRoot/_TestHelpers.ps1"
    . "$PSScriptRoot/fixtures/Import-AuditFixture.ps1"
    $script:fixtureDir = Join-Path $PSScriptRoot 'fixtures'
    $script:data       = Get-FixtureAuditData -FixtureDir $script:fixtureDir

    # Hand-authored oracle (kept in sync with tests/fixtures/README.md).
    $script:expectedBand = @{
        'Project Atlas Team'        = 'Confirmed'
        'Northwind Traders Admins'  = 'High'
        'NWT Application Owners'    = 'High'
        'Northwind Support'         = 'High'
        'NWT Finance Sync'          = 'High'
        'Logistics Integration RW'  = 'High'
        'Traders Data Feed'         = 'High'
        'APAC Vendor Access'        = 'High'
        'Northwind RW'              = 'High'
        'Global Logistics Stewards' = 'Medium'
    }
    $script:absent = @(
        'Contoso Service Desk','Contoso Billing Admins','Contoso EDI Integration',
        'Fabrikam Plant Ops','Fabrikam QA Team','Fabrikam Sensor Net',
        'Globex IT Admins','Globex Helpdesk','All Staff','Globex All Employees'
    )
}

Describe 'Fixture: engine pipeline (Northwind audit)' {
    BeforeAll {
        $auditInput = $script:data.InputData
        $knownKeys = @{}
        foreach ($k in $auditInput.KnownGroups)   { $knownKeys[(Get-GroupLookupKey -Domain $k.Domain -Identity $k.Identity)] = $true }
        $excludeKeys = @{}
        foreach ($e in $auditInput.ExcludeGroups) { $excludeKeys[(Get-GroupLookupKey -Domain $e.Domain -Identity $e.Identity)] = $true }

        $cand = Find-CandidateGroups -Groups $script:data.Groups -Keywords $auditInput.Keywords `
            -VendorUsers $script:data.VendorUsers -KnownKeys $knownKeys -ExcludeKeys $excludeKeys
        $cand = Expand-VendorGroupClosure -Results $cand
        $sel  = Select-AuditResults -Results $cand
        $sel  = Resolve-ResultDisplay -Results $sel -DnIndex $script:data.DnIndex -VendorUsers $script:data.VendorUsers

        $script:cand = $cand
        $script:sel  = $sel
        $script:byName = @{}
        foreach ($r in $sel) { $script:byName[$r.Name] = $r }
    }

    It 'surfaces exactly the 10 expected groups' {
        $expected = @($script:expectedBand.Keys | Sort-Object)
        $actual   = @($script:sel.Name | Sort-Object)
        $actual | Should -Be $expected
    }

    It 'assigns each surfaced group its expected confidence band' {
        foreach ($name in $script:expectedBand.Keys) {
            $script:byName[$name].Confidence | Should -Be $script:expectedBand[$name] -Because "band for '$name'"
        }
    }

    It 'promotes Global Logistics Stewards to Medium via nested-group closure' {
        $g = $script:byName['Global Logistics Stewards']
        $g.Confidence | Should -Be 'Medium'
        @($g.Reasons | Where-Object { $_.Pattern -eq 'NestedVendorGroup' }).Count | Should -BeGreaterThan 0
    }

    It 'marks the known group Confirmed with Source=Known' {
        $g = $script:byName['Project Atlas Team']
        $g.Confidence | Should -Be 'Confirmed'
        $g.Source     | Should -Be 'Known'
    }

    It 'resolves a cross-domain foreign-SID member to a vendor user' {
        $g = $script:byName['NWT Application Owners']
        $values = @($g.Reasons | Where-Object { $_.Pattern -eq 'MemberVendorUser' } | ForEach-Object { $_.Value })
        $values | Should -Contain 'Omar Haddad'
    }

    It 'matches a vendor user mentioned in a group description' {
        $g = $script:byName['Logistics Integration RW']
        $du = @($g.Reasons | Where-Object { $_.Pattern -eq 'DescriptionUser' })
        $du.Count | Should -BeGreaterThan 0
        ($du | ForEach-Object { $_.Value }) -join ' ' | Should -Match 'jbrooks'
    }

    It 'flags vendor members with a leading asterisk in the resolved member list' {
        $g = $script:byName['Northwind Traders Admins']
        $g.Members | Should -Contain '*Maria Hale'
    }

    It 'does not surface any decoy or excluded group' {
        foreach ($name in $script:absent) {
            $script:sel.Name | Should -Not -Contain $name -Because "'$name' must not surface"
        }
    }

    It 'MinimumConfidence High keeps Confirmed+High and drops Medium' {
        $high = Select-AuditResults -Results $script:cand -MinimumConfidence 'High'
        $high.Count | Should -Be 9
        $high.Name  | Should -Not -Contain 'Global Logistics Stewards'   # Medium -> dropped
        $high.Name  | Should -Contain 'Project Atlas Team'               # Confirmed -> kept
    }

    It 'SecurityGroupsOnly drops the distribution group (Northwind Support)' {
        $secGroups = @($script:data.Groups | Where-Object { "$($_.GroupCategory)" -eq 'Security' })
        $auditInput = $script:data.InputData
        $knownKeys = @{}
        foreach ($k in $auditInput.KnownGroups)   { $knownKeys[(Get-GroupLookupKey -Domain $k.Domain -Identity $k.Identity)] = $true }
        $excludeKeys = @{}
        foreach ($e in $auditInput.ExcludeGroups) { $excludeKeys[(Get-GroupLookupKey -Domain $e.Domain -Identity $e.Identity)] = $true }

        $c = Find-CandidateGroups -Groups $secGroups -Keywords $auditInput.Keywords `
            -VendorUsers $script:data.VendorUsers -KnownKeys $knownKeys -ExcludeKeys $excludeKeys
        $c = Expand-VendorGroupClosure -Results $c
        $s = Select-AuditResults -Results $c

        $s.Count | Should -Be 9
        $s.Name  | Should -Not -Contain 'Northwind Support'
        $s.Name  | Should -Contain 'Northwind Traders Admins'
    }
}
