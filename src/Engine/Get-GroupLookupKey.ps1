function Get-GroupLookupKey {
    # Canonical "domain|identity" lookup key (lowercased) used to match groups
    # against the known/exclude lists. Identity may be a group name or a DN.
    [CmdletBinding()]
    param([string]$Domain, [string]$Identity)
    ("{0}|{1}" -f $Domain, $Identity).ToLower()
}
