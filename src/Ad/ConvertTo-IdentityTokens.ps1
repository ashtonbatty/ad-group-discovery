function ConvertTo-IdentityTokens {
    [CmdletBinding()]
    param(
        [string]$SamAccountName, [string]$DisplayName, [string]$GivenName, [string]$Surname,
        [string]$Cn, [string]$Name, [string]$Upn, [string]$Mail, [string]$CsvDisplayName
    )
    $tokens = New-Object System.Collections.Generic.List[string]
    foreach ($v in @($SamAccountName, $DisplayName, $CsvDisplayName)) {
        if ($v) { $tokens.Add($v) }
    }
    @($tokens | Where-Object { $_ -and $_.Trim().Length -ge 3 } | Sort-Object -Unique)
}
