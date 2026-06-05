BeforeAll {
    . "$PSScriptRoot/_TestHelpers.ps1"
    $script:results = @(
        [pscustomobject]@{ Domain='corp'; Confidence='High';  Reasons=@([pscustomobject]@{Pattern='NameKeyword';Value='Acme'}) }
        [pscustomobject]@{ Domain='corp'; Confidence='Low';   Reasons=@([pscustomobject]@{Pattern='MemberVendorUser';Value='x'}) }
        [pscustomobject]@{ Domain='sub';  Confidence='Medium';Reasons=@([pscustomobject]@{Pattern='DescriptionKeyword';Value='Acme'}) }
    )
    $script:summary = [pscustomobject]@{ TotalGroups=3; FailedDomains=@('dead.example.com'); Warnings=@('one issue'); GeneratedAt='2026-06-05' }
}

Describe 'Write-ConsoleSummary' {
    It 'returns summary lines covering domains, bands, reasons, and failures' {
        $lines = @(Write-ConsoleSummary -Results $results -Summary $summary -AsString)
        ($lines -join "`n") | Should -Match 'corp'
        ($lines -join "`n") | Should -Match 'High'
        ($lines -join "`n") | Should -Match 'NameKeyword'
        ($lines -join "`n") | Should -Match 'dead.example.com'
    }
}
