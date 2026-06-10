function Get-FspSid {
    # A foreign-security-principal DN encodes the referenced principal's SID as its CN
    # (e.g. CN=S-1-5-21-...,CN=ForeignSecurityPrincipals,DC=...). Returns the SID,
    # or $null when the DN is not an FSP.
    [CmdletBinding()]
    param([string]$DistinguishedName)
    if ($DistinguishedName -match '^CN=(S-\d-[\d-]+)') { return $Matches[1] }
    $null
}
