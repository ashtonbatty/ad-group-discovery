function Get-OuComponentsFromDn {
    [CmdletBinding()]
    param([string]$DistinguishedName)
    if ([string]::IsNullOrWhiteSpace($DistinguishedName)) { return @() }
    $parts = $DistinguishedName -split '(?<!\\),'   # split on unescaped commas
    $containers = @()
    for ($i = 1; $i -lt $parts.Count; $i++) {       # skip leaf RDN at index 0
        $p = $parts[$i].Trim()
        if ($p -match '^(?:OU|CN)=(.+)$') { $containers += $Matches[1] }
    }
    $containers
}
