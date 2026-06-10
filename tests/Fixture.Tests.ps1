BeforeAll {
    . "$PSScriptRoot/_TestHelpers.ps1"
    . "$PSScriptRoot/fixtures/Import-DiscoveryFixture.ps1"
    $script:fixtureDir = Join-Path $PSScriptRoot 'fixtures'
    $script:data       = Get-FixtureDiscoveryData -FixtureDir $script:fixtureDir

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

Describe 'Fixture: engine pipeline (Northwind discovery)' {
    BeforeAll {
        $sel = Invoke-DiscoveryEngine -Groups $script:data.Groups -InputData $script:data.InputData `
            -VendorUsers $script:data.VendorUsers -DnIndex $script:data.DnIndex

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
        $high = Invoke-DiscoveryEngine -Groups $script:data.Groups -InputData $script:data.InputData `
            -VendorUsers $script:data.VendorUsers -DnIndex $script:data.DnIndex -MinimumConfidence 'High'
        $high.Count | Should -Be 9
        $high.Name  | Should -Not -Contain 'Global Logistics Stewards'   # Medium -> dropped
        $high.Name  | Should -Contain 'Project Atlas Team'               # Confirmed -> kept
    }

    It 'SecurityGroupsOnly drops the distribution group (Northwind Support)' {
        $secGroups = @($script:data.Groups | Where-Object { "$($_.GroupCategory)" -eq 'Security' })
        $s = Invoke-DiscoveryEngine -Groups $secGroups -InputData $script:data.InputData `
            -VendorUsers $script:data.VendorUsers -DnIndex $script:data.DnIndex

        $s.Count | Should -Be 9
        $s.Name  | Should -Not -Contain 'Northwind Support'
        $s.Name  | Should -Contain 'Northwind Traders Admins'
    }
}

Describe 'Fixture: public Find-VendorAdGroup (Northwind discovery)' {
    BeforeAll {
        $script:outDir = New-TestTempDir -Prefix 'fx'
        Mock -CommandName Get-AdDiscoveryData -MockWith {
            Get-FixtureDiscoveryData -FixtureDir $script:fixtureDir
        }
        $inDir = Join-Path $script:fixtureDir 'discovery-input'
        Find-VendorAdGroup `
            -UsersCsv        (Join-Path $inDir 'users.csv') `
            -DomainsCsv      (Join-Path $inDir 'domains.csv') `
            -KeywordsCsv     (Join-Path $inDir 'keywords.csv') `
            -KnownGroupsCsv  (Join-Path $inDir 'known.csv') `
            -ExcludeGroupsCsv (Join-Path $inDir 'exclude.csv') `
            -OutputDirectory $script:outDir -Formats @('Csv','Html') | Out-Null

        $script:csvRows = @(Import-Csv (Join-Path $script:outDir 'vendor-group-discovery.csv'))
        $script:html    = Get-Content (Join-Path $script:outDir 'vendor-group-discovery.html') -Raw
    }
    AfterAll { Remove-Item -Recurse -Force $script:outDir -ErrorAction SilentlyContinue }

    It 'writes a CSV with one row per surfaced group' {
        $script:csvRows.Count | Should -Be 10
    }

    It 'records the closure reason in the CSV' {
        $row = $script:csvRows | Where-Object { $_.Name -eq 'Global Logistics Stewards' }
        $row.MatchReasons | Should -Match 'NestedVendorGroup'
    }

    It 'records the known group as Confirmed in the CSV' {
        $row = $script:csvRows | Where-Object { $_.Name -eq 'Project Atlas Team' }
        $row.Confidence | Should -Be 'Confirmed'
    }

    It 'excludes decoy groups from the CSV' {
        $script:csvRows.Name | Should -Not -Contain 'Contoso Service Desk'
    }

    It 'flags vendor members with an asterisk in the CSV' {
        $row = $script:csvRows | Where-Object { $_.Name -eq 'Northwind Traders Admins' }
        $row.Members | Should -Match '\*Maria Hale'
    }

    It 'writes an HTML report containing the groups and a header per result domain' {
        $script:html | Should -Match '<html'
        $script:html | Should -Match 'Northwind Traders Admins'
        foreach ($dom in @('corp.globex.com','emea.globex.com','apac.globex.local','dmz.globex.net')) {
            $script:html | Should -Match ([regex]::Escape($dom))
        }
    }
}
