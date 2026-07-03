function Invoke-DiscoveryEngine {
    # Runs the full matching pipeline over already-acquired directory data:
    # candidate matching -> nested-group closure -> confidence filter -> display
    # resolution -> canonical sort. Single owner of the pipeline wiring, shared by
    # Find-VendorAdGroup, the fixture demo scripts, and the integration tests.
    [CmdletBinding()]
    param(
        [object[]]$Groups,
        [Parameter(Mandatory)][object]$InputData,
        [object[]]$VendorUsers,
        [hashtable]$DnIndex,
        [ValidateSet('Low','Medium','High','Confirmed')][string]$MinimumConfidence = 'Low'
    )
    $knownKeys = @{}
    foreach ($k in $InputData.KnownGroups)   { $knownKeys[(Get-GroupLookupKey -Domain $k.Domain -Identity $k.Identity)] = $true }
    $excludeKeys = @{}
    foreach ($e in $InputData.ExcludeGroups) { $excludeKeys[(Get-GroupLookupKey -Domain $e.Domain -Identity $e.Identity)] = $true }

    $engineTimer = [System.Diagnostics.Stopwatch]::StartNew()
    Write-DiscoveryLog ("Engine: scoring {0} group(s) against {1} keyword(s), {2} vendor user(s), {3} known, {4} excluded" -f `
        @($Groups).Count, @($InputData.Keywords).Count, @($VendorUsers).Count, $knownKeys.Count, $excludeKeys.Count)

    $candidates = Find-CandidateGroups -Groups $Groups -Keywords $InputData.Keywords `
        -VendorUsers $VendorUsers -KnownKeys $knownKeys -ExcludeKeys $excludeKeys
    Write-DiscoveryLog ("Engine: {0} group(s) matched at least one signal" -f @($candidates).Count)
    $candidates = Expand-VendorGroupClosure -Results $candidates
    $selected   = Select-DiscoveryResults -Results $candidates -MinimumConfidence $MinimumConfidence
    Write-DiscoveryLog ("Engine: {0} result(s) after nested-group closure, {1} at or above '{2}' confidence" -f `
        @($candidates).Count, @($selected).Count, $MinimumConfidence)
    $selected   = Resolve-ResultDisplay -Results $selected -DnIndex $DnIndex -VendorUsers $VendorUsers
    $sorted     = Sort-DiscoveryResult -Results $selected
    Write-DiscoveryLog ("Engine: pipeline complete in {0} ms" -f $engineTimer.ElapsedMilliseconds)
    $sorted
}
