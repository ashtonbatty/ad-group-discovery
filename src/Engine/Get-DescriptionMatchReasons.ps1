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
            # One reason per user, tagged with the first token that hit. Inline loop
            # (not Test-KeywordMatch) so this per-group/per-user hot path short-circuits
            # at the first match. Token hygiene (non-blank, >= 3 chars) is owned by
            # ConvertTo-IdentityTokens.
            foreach ($tok in $u.Tokens) {
                if ($text.IndexOf($tok, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                    $reasons.Add([pscustomobject]@{ Pattern = 'DescriptionUser'; Value = "$($u.SamAccountName) ~ $tok" })
                    break
                }
            }
        }
    }
    $reasons.ToArray()
}
