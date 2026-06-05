function Select-AuditResults {
    [CmdletBinding()]
    param([object[]]$Results, [ValidateSet('Low','Medium','High','Confirmed')][string]$MinimumConfidence = 'Low')
    $rank = @{ None = 0; Low = 1; Medium = 2; High = 3; Confirmed = 4 }
    $min  = $rank[$MinimumConfidence]
    @($Results | Where-Object { $rank[$_.Confidence] -ge 1 -and $rank[$_.Confidence] -ge $min })
}
