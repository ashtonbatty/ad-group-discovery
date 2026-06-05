function Test-KeywordMatch {
    [CmdletBinding()]
    param([string]$Text, [string[]]$Keywords)
    $found = @()
    if ([string]::IsNullOrWhiteSpace($Text)) { return $found }
    foreach ($k in $Keywords) {
        if ([string]::IsNullOrWhiteSpace($k)) { continue }
        if ($Text.IndexOf($k, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { $found += $k }
    }
    $found
}
