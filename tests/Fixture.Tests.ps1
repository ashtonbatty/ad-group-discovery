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
}
