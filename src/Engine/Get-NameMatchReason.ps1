function Get-NameMatchReason {
    [CmdletBinding()]
    param([string]$GroupName, [string[]]$Keywords)
    foreach ($k in (Test-KeywordMatch -Text $GroupName -Keywords $Keywords)) {
        [pscustomobject]@{ Pattern = 'NameKeyword'; Value = $k }
    }
}
