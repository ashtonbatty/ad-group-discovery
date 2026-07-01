function Get-DnDomainAndName {
    # Parse a distinguished name into its domain (DC components joined with '.')
    # and its leaf object name (the first RDN's value, DN-unescaped). Pure string
    # work: no directory access. Mirrors the unescaped-comma split in
    # Get-OuComponentsFromDn.
    [CmdletBinding()]
    param([string]$DistinguishedName)
    if ([string]::IsNullOrWhiteSpace($DistinguishedName)) {
        return [pscustomobject]@{ Domain = ''; Name = '' }
    }
    $parts = $DistinguishedName -split '(?<!\\),'   # split on unescaped commas
    $name = ''
    if ($parts.Count -gt 0 -and $parts[0].Trim() -match '^(?:CN|OU)=(.+)$') {
        $name = ($Matches[1] -replace '\\(.)', '$1')   # drop DN escape backslashes
    }
    $dcs = @()
    foreach ($p in $parts) {
        $t = $p.Trim()
        if ($t -match '^DC=(.+)$') { $dcs += $Matches[1] }
    }
    [pscustomobject]@{ Domain = ($dcs -join '.'); Name = $name }
}
