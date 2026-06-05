function Get-ContainerMatchReason {
    [CmdletBinding()]
    param([string]$DistinguishedName, [string[]]$Keywords)
    foreach ($ou in (Get-OuComponentsFromDn -DistinguishedName $DistinguishedName)) {
        foreach ($k in (Test-KeywordMatch -Text $ou -Keywords $Keywords)) {
            [pscustomobject]@{ Pattern = 'ContainerKeyword'; Value = "$ou ~ $k" }
        }
    }
}
