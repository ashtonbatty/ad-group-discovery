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
                        Description='Acme app'; Info=''; ManagedBy=''
                        Member=@('CN=John Smith,OU=Vendor,DC=corp,DC=example,DC=com'); MemberOf=@()
                        GroupScope='Global'; GroupCategory='Security'; Mail=$null; AdminCount=$null
                        WhenCreated=$null; WhenChanged=$null }
                )
                VendorUsers   = @(
                    [pscustomobject]@{ SamAccountName='jsmith'; DisplayName='John Smith'
                        Sid='S-1-5-21-1-2-3-1001'; Domain='corp.example.com'
                        DistinguishedName='CN=John Smith,OU=Vendor,DC=corp,DC=example,DC=com'
                        MemberOf=@('CN=Acme Admins,OU=Groups,DC=corp,DC=example,DC=com')
                        Enabled=$true; LockedOut=$false; Description='vendor'
                        AccountExpirationDate=$null; LastLogonDate=$null; PasswordLastSet=$null
                        BadLogonCount=0; PasswordNeverExpires=$false; PasswordExpiryComputed='0' }
                )
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
        $csv = Get-Item (Join-Path $out 'vendor-group-discovery.csv')
        $csv | Should -Not -BeNullOrEmpty
        (Import-Csv $csv.FullName)[0].Name | Should -Be 'Acme Admins'
        Test-Path (Join-Path $out 'vendor-group-discovery-members.csv') | Should -BeTrue
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
    It 'passes DomainCredentials through to AD discovery' {
        $out = Join-Path $tmp 'domain-credential-reports'
        $secret = [System.Security.SecureString]::new()
        $isolatedCredential = [System.Management.Automation.PSCredential]::new('ISOLATED\svc-ad-read', $secret)
        $domainCredentials = @{ 'isolated.example.com' = $isolatedCredential }

        Find-VendorAdGroup -UsersCsv "$tmp/users.csv" -DomainsCsv "$tmp/domains.csv" `
            -KeywordsCsv "$tmp/keywords.csv" -KnownGroupsCsv "$tmp/known.csv" -ExcludeGroupsCsv "$tmp/exclude.csv" `
            -OutputDirectory $out -Formats @('Csv') -DomainCredentials $domainCredentials

        Should -Invoke Get-AdDiscoveryData -Exactly -Times 1 -ParameterFilter {
            $DomainCredentials['isolated.example.com'] -eq $isolatedCredential
        }
    }
    It 'writes the user membership and account CSV reports' {
        $out = Join-Path $tmp 'user-reports'
        Find-VendorAdGroup -UsersCsv "$tmp/users.csv" -DomainsCsv "$tmp/domains.csv" `
            -KeywordsCsv "$tmp/keywords.csv" -KnownGroupsCsv "$tmp/known.csv" -ExcludeGroupsCsv "$tmp/exclude.csv" `
            -OutputDirectory $out -Formats @('Csv')
        Test-Path (Join-Path $out 'vendor-user-memberships.csv') | Should -BeTrue
        Test-Path (Join-Path $out 'vendor-user-accounts.csv') | Should -BeTrue
        $mem = @(Import-Csv (Join-Path $out 'vendor-user-memberships.csv'))
        ($mem | Where-Object { $_.UserSamAccountName -eq 'jsmith' -and $_.GroupName -eq 'Acme Admins' }) | Should -Not -BeNullOrEmpty
        $acc = @(Import-Csv (Join-Path $out 'vendor-user-accounts.csv'))
        ($acc | Where-Object UserSamAccountName -eq 'jsmith').Enabled | Should -Be 'True'
    }
    It 'writes the interactive JSON sidecar and viewer when Json format selected' {
        $out = Join-Path $tmp 'json-reports'
        Find-VendorAdGroup -UsersCsv "$tmp/users.csv" -DomainsCsv "$tmp/domains.csv" `
            -KeywordsCsv "$tmp/keywords.csv" -KnownGroupsCsv "$tmp/known.csv" -ExcludeGroupsCsv "$tmp/exclude.csv" `
            -OutputDirectory $out -Formats @('Json')
        Test-Path (Join-Path $out 'discovery-data.js')   | Should -BeTrue
        Test-Path (Join-Path $out 'discovery-data.json') | Should -BeTrue
        Test-Path (Join-Path $out 'discovery-report.html') | Should -BeTrue
        (Get-Content (Join-Path $out 'discovery-data.js') -Raw) | Should -Match 'window\.__DISCOVERY__'
        $data = Get-Content (Join-Path $out 'discovery-data.json') -Raw | ConvertFrom-Json
        $data.groups[0].name | Should -Be 'Acme Admins'
    }
}
