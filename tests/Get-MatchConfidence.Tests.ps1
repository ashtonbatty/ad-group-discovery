BeforeAll { . "$PSScriptRoot/_TestHelpers.ps1" }

Describe 'Get-MatchConfidence' {
    It 'bands a single strong signal as High' {
        $c = Get-MatchConfidence -Reasons @([pscustomobject]@{ Pattern='NameKeyword'; Value='Acme' })
        $c.Score | Should -Be 3
        $c.Confidence | Should -Be 'High'
    }
    It 'bands a single medium signal as Medium' {
        (Get-MatchConfidence -Reasons @([pscustomobject]@{ Pattern='DescriptionKeyword'; Value='Acme' })).Confidence | Should -Be 'Medium'
    }
    It 'bands a single member as Low' {
        (Get-MatchConfidence -Reasons @([pscustomobject]@{ Pattern='MemberVendorUser'; Value='x' })).Confidence | Should -Be 'Low'
    }
    It 'caps the member contribution at 3' {
        $reasons = 1..5 | ForEach-Object { [pscustomobject]@{ Pattern='MemberVendorUser'; Value="u$_" } }
        (Get-MatchConfidence -Reasons $reasons).Score | Should -Be 3
    }
    It 'returns Confirmed when known regardless of score' {
        (Get-MatchConfidence -Reasons @() -IsKnown).Confidence | Should -Be 'Confirmed'
    }
    It 'returns None for no reasons and not known' {
        (Get-MatchConfidence -Reasons @()).Confidence | Should -Be 'None'
    }
}
