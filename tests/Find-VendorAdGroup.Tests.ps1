BeforeAll {
    . "$PSScriptRoot/_TestHelpers.ps1"
    $script:tmp = New-TestTempDir -Prefix 'int'
    Set-Content "$tmp/users.csv"   "SamAccountName,DisplayName`njsmith,John Smith"
    Set-Content "$tmp/domains.csv" "Domain`ncorp.example.com"
    Set-Content "$tmp/keywords.csv" "Keyword`nAcme"
    Set-Content "$tmp/known.csv"   "Domain,Identity"
    Set-Content "$tmp/exclude.csv" "Domain,Identity"
}
AfterAll { Remove-Item -Recurse -Force $script:tmp -ErrorAction SilentlyContinue }

Describe 'Find-VendorAdGroup' {
    BeforeAll {
        Mock -CommandName Get-AdDiscoveryData -MockWith {
            [pscustomobject]@{
                Groups = @(
                    [pscustomobject]@{ Domain='corp.example.com'; Name='Acme Admins'
                        DistinguishedName='CN=Acme Admins,OU=Groups,DC=corp,DC=example,DC=com'
                        Description='Acme app'; Info=''; ManagedBy=''; Member=@(); MemberOf=@()
                        GroupScope='Global'; GroupCategory='Security'; Mail=$null; AdminCount=$null
                        WhenCreated=$null; WhenChanged=$null }
                )
                VendorUsers   = @()
                DnIndex       = @{}
                FailedDomains = @()
                Warnings      = @()
            }
        }
    }
    It 'produces a CSV report containing the discovered group' {
        $out = Join-Path $tmp 'reports'
        Find-VendorAdGroup -UsersCsv "$tmp/users.csv" -DomainsCsv "$tmp/domains.csv" `
            -KeywordsCsv "$tmp/keywords.csv" -KnownGroupsCsv "$tmp/known.csv" -ExcludeGroupsCsv "$tmp/exclude.csv" `
            -OutputDirectory $out -Formats @('Csv')
        $csv = Get-ChildItem $out -Filter '*.csv' | Select-Object -First 1
        $csv | Should -Not -BeNullOrEmpty
        (Import-Csv $csv.FullName)[0].Name | Should -Be 'Acme Admins'
    }
    It 'passes SecurityGroupsOnly through to AD discovery' {
        $out = Join-Path $tmp 'security-reports'
        Find-VendorAdGroup -UsersCsv "$tmp/users.csv" -DomainsCsv "$tmp/domains.csv" `
            -KeywordsCsv "$tmp/keywords.csv" -KnownGroupsCsv "$tmp/known.csv" -ExcludeGroupsCsv "$tmp/exclude.csv" `
            -OutputDirectory $out -Formats @('Csv') -SecurityGroupsOnly
        Should -Invoke Get-AdDiscoveryData -Exactly -Times 1 -ParameterFilter {
            $SecurityGroupsOnly
        }
    }
}
