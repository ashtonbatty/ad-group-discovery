function ConvertTo-LdapFilterValue {
    # RFC 4515 escaping for a value embedded in an LDAP search filter.
    # Backslash must be escaped first or it would re-escape the other sequences.
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)
    $escaped = $Value -replace '\\', '\5c'
    $escaped = $escaped -replace '\*', '\2a'
    $escaped = $escaped -replace '\(', '\28'
    $escaped = $escaped -replace '\)', '\29'
    $escaped -replace "`0", '\00'
}

function New-SamLdapFilter {
    # Builds an OR'd sAMAccountName LDAP filter for a batch of names.
    param([Parameter(Mandatory)][AllowEmptyCollection()][string[]]$SamAccountNames)
    $clauses = @(foreach ($s in $SamAccountNames) {
        "(sAMAccountName=$(ConvertTo-LdapFilterValue -Value $s))"
    })
    if ($clauses.Count -eq 0) { return '' }
    if ($clauses.Count -eq 1) { return $clauses[0] }
    "(|$($clauses -join ''))"
}
