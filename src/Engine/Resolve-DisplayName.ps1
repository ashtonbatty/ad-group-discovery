function Resolve-DisplayName {
    [CmdletBinding()]
    param([string]$Identity, [hashtable]$DnIndex)
    if ([string]::IsNullOrWhiteSpace($Identity)) { return '' }
    $k = $Identity.ToLower()
    if ($DnIndex -and $DnIndex.ContainsKey($k)) { return $DnIndex[$k] }
    if ($Identity -match '^CN=(S-\d-[\d-]+)') { return "$($Matches[1]) [unresolved]" }
    if ($Identity -match '^(?:CN|OU)=([^,]+)') { return $Matches[1] }
    return $Identity
}
