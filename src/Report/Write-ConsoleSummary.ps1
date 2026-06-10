function Write-ConsoleSummary {
    [CmdletBinding()]
    param([object[]]$Results, [object]$Summary, [switch]$AsString)
    $lines = @()
    $lines += '=== Vendor AD Group Discovery Summary ==='
    $lines += "Generated:       $($Summary.GeneratedAt)"
    $lines += "Groups reported: $(@($Results).Count)"
    $lines += ''
    $lines += 'By domain:'
    foreach ($g in ($Results | Group-Object Domain | Sort-Object Name)) {
        $lines += ("  {0,-30} {1}" -f $g.Name, $g.Count)
    }
    $lines += ''
    $lines += 'By confidence:'
    $rank = Get-ConfidenceRank
    $bandCounts = @{}
    foreach ($g in ($Results | Group-Object Confidence)) { $bandCounts[$g.Name] = $g.Count }
    # Band list and order derive from the canonical rank table (None is never reported).
    foreach ($band in ($rank.Keys | Where-Object { $rank[$_] -gt 0 } | Sort-Object { $rank[$_] } -Descending)) {
        $lines += ("  {0,-12} {1}" -f $band, [int]$bandCounts[$band])
    }
    $lines += ''
    $lines += 'By match reason:'
    $allReasons = @($Results | ForEach-Object { $_.Reasons }) | Where-Object { $_ }
    foreach ($g in ($allReasons | Group-Object Pattern | Sort-Object Name)) {
        $lines += ("  {0,-20} {1}" -f $g.Name, $g.Count)
    }
    if (@($Summary.FailedDomains).Count) {
        $lines += ''
        $lines += 'Failed domains (not discovered):'
        foreach ($d in $Summary.FailedDomains) { $lines += "  $d" }
    }
    if (@($Summary.Warnings).Count) {
        $lines += ''
        $lines += "Warnings: $(@($Summary.Warnings).Count) (see HTML report)"
    }

    if ($AsString) { return $lines }
    $lines | ForEach-Object { Write-Host $_ }
}
