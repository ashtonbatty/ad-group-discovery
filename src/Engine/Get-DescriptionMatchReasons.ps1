function Get-DescriptionMatchReasons {
    [CmdletBinding()]
    param([string]$Description, [string]$Info, [string[]]$Keywords, [object[]]$VendorUsers)
    $reasons = @()
    $text = @($Description, $Info) -join ' '
    foreach ($k in (Test-KeywordMatch -Text $text -Keywords $Keywords)) {
        $reasons += [pscustomobject]@{ Pattern = 'DescriptionKeyword'; Value = $k }
    }
    if (-not [string]::IsNullOrWhiteSpace($text)) {
        foreach ($u in $VendorUsers) {
            foreach ($tok in $u.Tokens) {
                if ([string]::IsNullOrWhiteSpace($tok) -or $tok.Trim().Length -lt 3) { continue }
                if ($text.IndexOf($tok, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                    $reasons += [pscustomobject]@{ Pattern = 'DescriptionUser'; Value = "$($u.SamAccountName) ~ $tok" }
                    break   # one reason per user
                }
            }
        }
    }
    $reasons
}
