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
            foreach ($tok in $u.Tokens) {
                if ([string]::IsNullOrWhiteSpace($tok) -or $tok.Trim().Length -lt 3) { continue }
                if ($text.IndexOf($tok, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                    $reasons.Add([pscustomobject]@{ Pattern = 'DescriptionUser'; Value = "$($u.SamAccountName) ~ $tok" })
                    break   # one reason per user
                }
            }
        }
    }
    $reasons.ToArray()
}
