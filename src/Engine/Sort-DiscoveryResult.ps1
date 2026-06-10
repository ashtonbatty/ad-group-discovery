function Sort-DiscoveryResult {
    # Canonical presentation order for results: confidence band (descending),
    # then Domain, then Name. Single owner of the sort policy.
    # 'Sort' is unapproved but is the precise verb here (cf. Sort-Object); internal-only.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseApprovedVerbs', '')]
    [CmdletBinding()]
    param([object[]]$Results)
    $rank = Get-ConfidenceRank
    ,@($Results | Sort-Object @{ Expression = { $rank[$_.Confidence] }; Descending = $true }, Domain, Name)
}
