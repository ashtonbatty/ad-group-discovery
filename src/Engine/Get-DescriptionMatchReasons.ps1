function Get-DescriptionMatchReasons {
    [CmdletBinding()]
    param([string]$Description, [string]$Info, [string[]]$Keywords, [object[]]$VendorUsers)
    $reasons = New-Object System.Collections.Generic.List[object]
    $text = @($Description, $Info) -join ' '
    foreach ($k in (Test-KeywordMatch -Text $text -Keywords $Keywords)) {
        $reasons.Add([pscustomobject]@{ Pattern = 'DescriptionKeyword'; Value = $k })
    }
    if (-not [string]::IsNullOrWhiteSpace($text)) {
        foreach ($u in $VendorUsers) {
            # One reason per user, tagged with the first token that hit. Token hygiene
            # (non-blank, >= 3 chars) is owned by ConvertTo-IdentityTokens.
            $tok = @(Test-KeywordMatch -Text $text -Keywords $u.Tokens) | Select-Object -First 1
            if ($tok) {
                $reasons.Add([pscustomobject]@{ Pattern = 'DescriptionUser'; Value = "$($u.SamAccountName) ~ $tok" })
            }
        }
    }
    $reasons.ToArray()
}
