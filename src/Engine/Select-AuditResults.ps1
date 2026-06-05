function Select-AuditResults {
    [CmdletBinding()]
    param([object[]]$Results, [ValidateSet('Low','Medium','High','Confirmed')][string]$MinimumConfidence = 'Low')
    $rank = Get-ConfidenceRank
    $min  = $rank[$MinimumConfidence]
    # $min is always >= 1 (ValidateSet excludes None), so this also drops None.
    @($Results | Where-Object { $rank[$_.Confidence] -ge $min })
}
