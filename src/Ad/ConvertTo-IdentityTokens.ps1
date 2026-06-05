function ConvertTo-IdentityTokens {
    [CmdletBinding()]
    param(
        [string]$SamAccountName, [string]$DisplayName, [string]$GivenName, [string]$Surname,
        [string]$Cn, [string]$Name, [string]$Upn, [string]$Mail, [string]$CsvDisplayName
    )
    $tokens = New-Object System.Collections.Generic.List[string]
    foreach ($v in @($SamAccountName, $DisplayName, $Cn, $Name, $Upn, $Mail, $CsvDisplayName)) {
        if ($v) { $tokens.Add($v) }
    }
    if ($GivenName -and $Surname) {
        $tokens.Add("$GivenName $Surname")
        $tokens.Add("$Surname, $GivenName")
        $tokens.Add("$Surname $GivenName")
    }
    @($tokens | Where-Object { $_ -and $_.Trim().Length -ge 3 } | Sort-Object -Unique)
}
