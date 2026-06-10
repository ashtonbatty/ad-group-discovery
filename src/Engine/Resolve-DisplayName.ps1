function Resolve-DisplayName {
    [CmdletBinding()]
    param([string]$Identity, [hashtable]$DnIndex)
    if ([string]::IsNullOrWhiteSpace($Identity)) { return '' }
    $k = $Identity.ToLower()
    if ($DnIndex -and $DnIndex.ContainsKey($k)) { return $DnIndex[$k] }
    $sid = Get-FspSid -DistinguishedName $Identity
    if ($sid) { return "$sid [unresolved]" }
    if ($Identity -match '^(?:CN|OU)=([^,]+)') { return $Matches[1] }
    return $Identity
}
