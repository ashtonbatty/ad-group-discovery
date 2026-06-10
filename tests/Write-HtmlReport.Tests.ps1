BeforeAll {
    . "$PSScriptRoot/_TestHelpers.ps1"
    $script:tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("html_" + [guid]::NewGuid())
    New-Item -ItemType Directory -Path $script:tmp | Out-Null
    $script:results = @(
        [pscustomobject]@{ Domain='corp'; Name='Acme <Admins>'; DistinguishedName='CN=Acme Admins,DC=c'
            Description='Acme'; Info=''; Owner='John Smith'; Members=@('*John Smith'); MemberOfDisplay=@()
            GroupScope='Global'; GroupCategory='Security'; Mail=$null; AdminCount=$null
            WhenCreated=$null; WhenChanged=$null; Confidence='High'; Score=3
            Reasons=@([pscustomobject]@{Pattern='NameKeyword';Value='Acme'}); Source='Discovered' }
    )
    $script:summary = [pscustomobject]@{ TotalGroups=1; FailedDomains=@(); Warnings=@(); GeneratedAt='2026-06-05' }
}
AfterAll { Remove-Item -Recurse -Force $script:tmp -ErrorAction SilentlyContinue }

Describe 'Write-HtmlReport' {
    It 'writes self-contained HTML containing the group and escaping markup' {
        $path = Join-Path $tmp 'out.html'
        Write-HtmlReport -Results $results -Summary $summary -Path $path
        $html = Get-Content $path -Raw
        $html | Should -Match '<html'
        $html | Should -Match 'Acme &lt;Admins&gt;'   # HTML-escaped
        $html | Should -Match 'NameKeyword'
    }
    It 'uses double-quoted class attribute for the confidence band' {
        $path = Join-Path $tmp 'class.html'
        Write-HtmlReport -Results $results -Summary $summary -Path $path
        $html = Get-Content $path -Raw
        $html | Should -Match 'class="High"'
    }
    It 'includes escaped warning messages in the summary' {
        $path = Join-Path $tmp 'warnings.html'
        $summaryWithWarnings = [pscustomobject]@{
            TotalGroups = 1
            FailedDomains = @()
            Warnings = @("Lookup failed for user '<script>alert(1)</script>'")
            GeneratedAt = '2026-06-05'
        }
        Write-HtmlReport -Results $results -Summary $summaryWithWarnings -Path $path
        $html = Get-Content $path -Raw
        $html | Should -Match 'Warnings: 1'
        $html | Should -Match 'Lookup failed for user'
        $html | Should -Match '&lt;script&gt;alert\(1\)&lt;/script&gt;'
        $html | Should -Not -Match '<script>alert\(1\)</script>'
    }
}
