function ConvertTo-IdentityTokens {
    [CmdletBinding()]
    param(
        [string]$SamAccountName, [string]$Mail
    )
    $tokens = New-Object System.Collections.Generic.List[string]
    # Description owner references are reliable only when they use a directory
    # identifier. Display names remain available for reports, but are deliberately
    # excluded here because "Display Name (sam)" may name an unrelated account.
    foreach ($v in @($SamAccountName, $Mail)) {
        if ($v) { $tokens.Add($v) }
    }
    @($tokens | Where-Object { $_ -and $_.Trim().Length -ge 3 } | Sort-Object -Unique)
}
