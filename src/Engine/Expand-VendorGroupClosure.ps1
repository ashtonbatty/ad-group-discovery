function Expand-VendorGroupClosure {
    [CmdletBinding()]
    param([object[]]$Results, [int]$MaxIterations = 25)

    for ($round = 0; $round -lt $MaxIterations; $round++) {
        # Confirmed seeds this round: known, or score >= 2 (direct or already-promoted).
        $confirmed = @{}
        foreach ($r in $Results) {
            if ($r.IsKnown -or $r.Score -ge 2) { $confirmed[$r.DistinguishedName.ToLower()] = $r }
        }

        $changed = $false
        foreach ($r in $Results) {
            foreach ($m in @($r.Member)) {
                if ([string]::IsNullOrWhiteSpace($m)) { continue }
                $mk = $m.ToLower()
                if (-not $confirmed.ContainsKey($mk)) { continue }
                $child = $confirmed[$mk]
                if ($child.DistinguishedName -ieq $r.DistinguishedName) { continue }   # ignore self
                $already = $r.Reasons | Where-Object { $_.Pattern -eq 'NestedVendorGroup' -and $_.Value -eq $child.Name }
                if ($already) { continue }

                $r.Reasons = @($r.Reasons) + [pscustomobject]@{ Pattern = 'NestedVendorGroup'; Value = $child.Name }
                $cc = Get-MatchConfidence -Reasons $r.Reasons -IsKnown:$r.IsKnown
                $r.Score = $cc.Score
                $r.Confidence = $cc.Confidence
                $changed = $true
            }
        }
        if (-not $changed) { break }
    }
    ,$Results
}
