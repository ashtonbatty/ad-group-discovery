# Reason weights for confidence scoring. Module/script scope so the table is built
# once, not on every call in the per-group hot path.
$script:MatchReasonWeights = @{
    NameKeyword = 3; ContainerKeyword = 3; Owner = 3
    DescriptionUser = 2; DescriptionKeyword = 2; NestedVendorGroup = 2
    MemberVendorUser = 1
}

function Get-MatchConfidence {
    [CmdletBinding()]
    param([object[]]$Reasons, [switch]$IsKnown)
    $weights = $script:MatchReasonWeights
    $score = 0; $memberScore = 0
    foreach ($r in @($Reasons)) {
        if ($null -eq $r) { continue }
        if ($r.Pattern -eq 'MemberVendorUser') { $memberScore += 1 }
        elseif ($weights.ContainsKey($r.Pattern)) { $score += $weights[$r.Pattern] }
    }
    $score += [System.Math]::Min(3, $memberScore)

    if ($IsKnown)            { $confidence = 'Confirmed' }
    elseif ($score -ge 3)    { $confidence = 'High' }
    elseif ($score -ge 2)    { $confidence = 'Medium' }
    elseif ($score -ge 1)    { $confidence = 'Low' }
    else                     { $confidence = 'None' }

    [pscustomobject]@{ Score = $score; Confidence = $confidence }
}
