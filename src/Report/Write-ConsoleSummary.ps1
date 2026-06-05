function Write-ConsoleSummary {
    [CmdletBinding()]
    param([object[]]$Results, [object]$Summary, [switch]$AsString)
    $lines = @()
    $lines += '=== AD Vendor Group Audit Summary ==='
    $lines += "Generated:       $($Summary.GeneratedAt)"
    $lines += "Groups reported: $(@($Results).Count)"
    $lines += ''
    $lines += 'By domain:'
    foreach ($g in ($Results | Group-Object Domain | Sort-Object Name)) {
        $lines += ("  {0,-30} {1}" -f $g.Name, $g.Count)
    }
    $lines += ''
    $lines += 'By confidence:'
    foreach ($band in @('Confirmed','High','Medium','Low')) {
        $n = @($Results | Where-Object Confidence -eq $band).Count
        $lines += ("  {0,-12} {1}" -f $band, $n)
    }
    $lines += ''
    $lines += 'By match reason:'
    $reasonCounts = @{}
    foreach ($r in $Results) {
        foreach ($reason in @($r.Reasons)) {
            if ($null -eq $reason) { continue }
            $reasonCounts[$reason.Pattern] = $reasonCounts[$reason.Pattern] + 1   # $null + 1 = 1 for a new key
        }
    }
    foreach ($k in ($reasonCounts.Keys | Sort-Object)) {
        $lines += ("  {0,-20} {1}" -f $k, $reasonCounts[$k])
    }
    if (@($Summary.FailedDomains).Count) {
        $lines += ''
        $lines += 'Failed domains (not audited):'
        foreach ($d in $Summary.FailedDomains) { $lines += "  $d" }
    }
    if (@($Summary.Warnings).Count) {
        $lines += ''
        $lines += "Warnings: $(@($Summary.Warnings).Count) (see HTML report)"
    }

    if ($AsString) { return $lines }
    $lines | ForEach-Object { Write-Host $_ }
}
