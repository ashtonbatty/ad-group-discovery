BeforeAll {
    . "$PSScriptRoot/_TestHelpers.ps1"
    $script:tmp = New-TestTempDir -Prefix 'json'
    $script:results = @(
        [pscustomobject]@{
            Domain='corp'; Name='Acme Admins'; Confidence='High'; Score=3
            Source='Discovered'; Description='=cmd|calc'; Info='note'; Owner='John Smith'
            MemberOfDisplay=@('Parent Group'); GroupScope='Global'; GroupCategory='Security'
            Mail=$null; AdminCount=1; WhenCreated='2020'; WhenChanged='2021'
            DistinguishedName='CN=Acme Admins,DC=c'
            Reasons=@([pscustomobject]@{ Pattern='NameKeyword'; Value='Acme' })
            MemberDetails=@(
                [pscustomobject]@{ MemberType='Known';       SamAccountName='jsmith'; DisplayName='John Smith'; DistinguishedName='CN=John Smith,DC=c' }
                [pscustomobject]@{ MemberType='NestedGroup'; SamAccountName='';       DisplayName='Sub Group';  DistinguishedName='CN=Sub,DC=c' }
                [pscustomobject]@{ MemberType='Other';       SamAccountName='bob';    DisplayName='Bob';        DistinguishedName='CN=Bob,DC=c' }
            )
        }
    )
    $script:summary = [pscustomobject]@{ TotalGroups=1; FailedDomains=@(); Warnings=@('watch out'); GeneratedAt='2026-07-03 10:00:00' }
    Write-JsonReport -Results $script:results -Summary $script:summary -OutputDirectory $script:tmp
    $script:jsonPath = Join-Path $script:tmp 'discovery-data.json'
    $script:jsPath   = Join-Path $script:tmp 'discovery-data.js'
}
AfterAll { Remove-Item -Recurse -Force $script:tmp -ErrorAction SilentlyContinue }

Describe 'Write-JsonReport' {
    It 'writes both the .js and .json sidecar files' {
        Test-Path $script:jsonPath | Should -BeTrue
        Test-Path $script:jsPath   | Should -BeTrue
    }
    It 'wraps the payload in the window.__DISCOVERY__ global in the .js file' {
        (Get-Content $script:jsPath -Raw) | Should -Match 'window\.__DISCOVERY__ ='
    }
    It 'round-trips a nested payload preserving members and reasons' {
        $data = Get-Content $script:jsonPath -Raw | ConvertFrom-Json
        $data.summary.totalGroups | Should -Be 1
        $g = $data.groups[0]
        $g.name | Should -Be 'Acme Admins'
        $g.confidence | Should -Be 'High'
        $g.reasons[0].pattern | Should -Be 'NameKeyword'
        @($g.members).Count | Should -Be 3
        $g.memberCounts.known  | Should -Be 1
        $g.memberCounts.nested | Should -Be 1
        $g.memberCounts.other  | Should -Be 1
        @($g.memberOf) | Should -Contain 'Parent Group'
    }
    It 'does not apply CSV injection hardening to values' {
        $data = Get-Content $script:jsonPath -Raw | ConvertFrom-Json
        # Description keeps its leading '=' with no apostrophe/tab prefix (that is a CSV-only concern).
        $data.groups[0].description | Should -Be '=cmd|calc'
    }
    It 'treats $null array-shaped properties as empty, not a one-element array containing $null' {
        $nullTmp = New-TestTempDir -Prefix 'json-null'
        try {
            $nullResults = @(
                [pscustomobject]@{
                    Domain='corp'; Name='Null Group'; Confidence='Low'; Score=1
                    Source='Discovered'; Description=''; Info=''; Owner=''
                    MemberOfDisplay=$null; GroupScope='Global'; GroupCategory='Security'
                    Mail=$null; AdminCount=0; WhenCreated='2020'; WhenChanged='2021'
                    DistinguishedName='CN=Null Group,DC=c'
                    Reasons=$null
                    MemberDetails=$null
                }
            )
            $nullSummary = [pscustomobject]@{ TotalGroups=1; FailedDomains=$null; Warnings=$null; GeneratedAt='2026-07-03 10:00:00' }
            Write-JsonReport -Results $nullResults -Summary $nullSummary -OutputDirectory $nullTmp
            $data = Get-Content (Join-Path $nullTmp 'discovery-data.json') -Raw | ConvertFrom-Json
            $g = $data.groups[0]
            @($g.members).Count  | Should -Be 0
            @($g.reasons).Count  | Should -Be 0
            @($g.memberOf).Count | Should -Be 0
            $g.memberCounts.known  | Should -Be 0
            $g.memberCounts.nested | Should -Be 0
            $g.memberCounts.other  | Should -Be 0
            @($data.summary.failedDomains).Count | Should -Be 0
            @($data.summary.warnings).Count | Should -Be 0
        }
        finally {
            Remove-Item -Recurse -Force $nullTmp -ErrorAction SilentlyContinue
        }
    }
}
