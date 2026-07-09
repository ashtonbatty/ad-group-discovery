function ConvertTo-IdentityTokens {
    [CmdletBinding()]
    param(
        [string]$SamAccountName, [string]$UUserId, [string]$Mail
    )
    $tokens = New-Object System.Collections.Generic.List[string]
    # Description owner references are reliable only when they use a directory
    # identifier. Display names remain available for reports, but are deliberately
    # excluded here because "Display Name (identifier)" may name an unrelated account.
    foreach ($v in @($SamAccountName, $UUserId, $Mail)) {
        if ($v) { $tokens.Add($v) }
    }
    # Longest-first (ties alphabetical): Get-DescriptionMatchReasons consumes
    # tokens in array order on the per-group hot path, so the most specific
    # token (email over sam) must already lead here rather than be re-sorted
    # once per (group, user) pair.
    @($tokens | Where-Object { $_ -and $_.Trim().Length -ge 3 } | Sort-Object -Unique |
        Sort-Object -Property @{ Expression = 'Length'; Descending = $true }, @{ Expression = { $_ } })
}
