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
        [ValidateSet('Low','Medium','High','Confirmed')][string]$MinimumConfidence = 'Low',
        [int]$MaxIterations = 25
    )
    $knownKeys = @{}
    foreach ($k in $InputData.KnownGroups)   { $knownKeys[(Get-GroupLookupKey -Domain $k.Domain -Identity $k.Identity)] = $true }
    $excludeKeys = @{}
    foreach ($e in $InputData.ExcludeGroups) { $excludeKeys[(Get-GroupLookupKey -Domain $e.Domain -Identity $e.Identity)] = $true }

    $candidates = Find-CandidateGroups -Groups $Groups -Keywords $InputData.Keywords `
        -VendorUsers $VendorUsers -KnownKeys $knownKeys -ExcludeKeys $excludeKeys
    $candidates = Expand-VendorGroupClosure -Results $candidates -MaxIterations $MaxIterations
    $selected   = Select-DiscoveryResults -Results $candidates -MinimumConfidence $MinimumConfidence
    $selected   = Resolve-ResultDisplay -Results $selected -DnIndex $DnIndex -VendorUsers $VendorUsers
    Sort-DiscoveryResult -Results $selected
}
