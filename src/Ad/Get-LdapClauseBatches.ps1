function Get-LdapClauseBatches {
    # Splits LDAP filter clauses into batches bounded by clause count and total
    # character size so OR'd filters stay well under directory limits (a prod DC
    # accepted a 159 KB filter, so the defaults keep a comfortable margin while
    # minimizing the number of searches -- unindexed contains-filters cost one
    # full directory scan PER SEARCH, so fewer, larger batches are cheaper).
    #
    # Returns object[] of string[] batches. Callers iterate the result directly
    # (foreach ($batch in Get-LdapClauseBatches ...)); each element is one batch.
    # NOTE: no comma-wrapping on return -- the pipeline unrolls exactly one
    # level, emitting each string[] batch as one item. A ,-wrap combined with
    # an @()-wrapping caller is what re-created the historical flattening bug;
    # keep both out.
    [CmdletBinding()]
    param(
        [string[]]$Clauses,
        [int]$MaxClauses = 1000,
        [int]$MaxChars = 120000
    )
    $batches = New-Object System.Collections.Generic.List[object]
    $current = New-Object System.Collections.Generic.List[string]
    $currentChars = 0
    foreach ($clause in @($Clauses)) {
        if ([string]::IsNullOrEmpty($clause)) { continue }
        $overflow = ($current.Count -ge $MaxClauses) -or
            ($current.Count -gt 0 -and ($currentChars + $clause.Length) -gt $MaxChars)
        if ($overflow) {
            $batches.Add($current.ToArray())
            $current = New-Object System.Collections.Generic.List[string]
            $currentChars = 0
        }
        $current.Add($clause)
        $currentChars += $clause.Length
    }
    if ($current.Count -gt 0) { $batches.Add($current.ToArray()) }
    return $batches.ToArray()
}
