function Expand-VendorGroupClosure {
    [CmdletBinding()]
    param([object[]]$Results, [int]$MaxIterations = 25)

    $rank = Get-ConfidenceRank
    $seedRank = $rank['Medium']

    for ($round = 0; $round -lt $MaxIterations; $round++) {
        # Confirmed seeds this round: known, or at least Medium band (direct or already-promoted).
        $confirmed = @{}
        $trustedNames = @{}
        foreach ($r in $Results) {
            if ($r.IsKnown -or $rank[$r.Confidence] -ge $seedRank) { $confirmed[$r.DistinguishedName.ToLower()] = $r }
            # Trusted-name eligibility lives in Test-TrustedNameSource (shared
            # with the fetch layer in Get-AdDiscoveryData). DescriptionGroup is
            # itself a non-member reason, so trust keeps propagating
            # transitively on later rounds.
            if (Test-TrustedNameSource -Result $r -Rank $rank) {
                $name = "$($r.Name)".Trim()
                if (-not [string]::IsNullOrWhiteSpace($name)) {
                    $nameKey = $name.ToLower()
                    if (-not $trustedNames.ContainsKey($nameKey)) {
                        # Match the name as a whole word only: a raw substring match
                        # lets short/common names ("IT") hit unrelated text
                        # ("secur-IT-y"). Word-char lookarounds (rather than \b) so
                        # names that begin/end with punctuation -- e.g. "Finance
                        # (EMEA)" -- still match verbatim. Compiled once per round
                        # and reused across all results.
                        $pattern = '(?<!\w)' + [regex]::Escape($name) + '(?!\w)'
                        $trustedNames[$nameKey] = [pscustomobject]@{
                            Name  = $name
                            Dns   = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
                            Regex = [regex]::new($pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
                        }
                    }
                    [void]$trustedNames[$nameKey].Dns.Add($r.DistinguishedName)
                }
            }
        }

        $changed = $false
        foreach ($r in $Results) {
            foreach ($m in @($r.Member)) {
                if ([string]::IsNullOrWhiteSpace($m)) { continue }
                $mk = $m.ToLower()
                if (-not $confirmed.ContainsKey($mk)) { continue }
                $child = $confirmed[$mk]
                if ($child.DistinguishedName -ieq $r.DistinguishedName) { continue }   # ignore self
                $already = $r.Reasons | Where-Object { $_.Pattern -eq 'NestedVendorGroup' -and $_.ChildDn -ieq $child.DistinguishedName }
                if ($already) { continue }

                $r.Reasons = @($r.Reasons) + [pscustomobject]@{ Pattern = 'NestedVendorGroup'; Value = $child.Name; ChildDn = $child.DistinguishedName }
                $cc = Get-MatchConfidence -Reasons $r.Reasons -IsKnown:$r.IsKnown
                $r.Score = $cc.Score
                $r.Confidence = $cc.Confidence
                $changed = $true
            }

            $text = @($r.Description, $r.Info) -join ' '
            if ([string]::IsNullOrWhiteSpace($text)) { continue }
            foreach ($trusted in $trustedNames.Values) {
                # A group's own name is not evidence unless a distinct trusted
                # group with the same name exists.
                $hasOtherGroup = $trusted.Dns.Count -gt 1 -or -not $trusted.Dns.Contains($r.DistinguishedName)
                if (-not $hasOtherGroup) { continue }
                if (-not $trusted.Regex.IsMatch($text)) { continue }
                $already = $r.Reasons | Where-Object { $_.Pattern -eq 'DescriptionGroup' -and $_.Value -ieq $trusted.Name }
                if ($already) { continue }
                $r.Reasons = @($r.Reasons) + [pscustomobject]@{ Pattern = 'DescriptionGroup'; Value = $trusted.Name }
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
