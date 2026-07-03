function Write-JsonReport {
    # Pure writer: shapes engine results into a plain payload and emits two sidecar
    # files next to the interactive viewer. No CSV-style injection hardening -- JSON is
    # inherently injection-safe; the viewer escapes at render time.
    [CmdletBinding()]
    param(
        [object[]]$Results,
        [Parameter(Mandatory)][object]$Summary,
        [Parameter(Mandatory)][string]$OutputDirectory
    )

    function ConvertTo-MemberObject {
        param([object]$Member)
        [ordered]@{
            memberType        = [string]$Member.MemberType
            samAccountName    = [string]$Member.SamAccountName
            displayName       = [string]$Member.DisplayName
            distinguishedName = [string]$Member.DistinguishedName
        }
    }

    $groups = foreach ($r in $Results) {
        $memberDetails = @($r.MemberDetails)
        $known  = @($memberDetails | Where-Object { $_.MemberType -eq 'Known' }).Count
        $nested = @($memberDetails | Where-Object { $_.MemberType -eq 'NestedGroup' }).Count
        $other  = @($memberDetails | Where-Object { $_.MemberType -ne 'Known' -and $_.MemberType -ne 'NestedGroup' }).Count
        [ordered]@{
            domain            = [string]$r.Domain
            name              = [string]$r.Name
            confidence        = [string]$r.Confidence
            score             = $r.Score
            source            = [string]$r.Source
            description       = [string]$r.Description
            info              = [string]$r.Info
            owner             = [string]$r.Owner
            memberOf          = @(@($r.MemberOfDisplay) | ForEach-Object { [string]$_ })
            groupScope        = [string]$r.GroupScope
            groupCategory     = [string]$r.GroupCategory
            mail              = [string]$r.Mail
            adminCount        = $r.AdminCount
            whenCreated       = [string]$r.WhenCreated
            whenChanged       = [string]$r.WhenChanged
            distinguishedName = [string]$r.DistinguishedName
            reasons           = @(@($r.Reasons) | ForEach-Object { [ordered]@{ pattern = [string]$_.Pattern; value = [string]$_.Value } })
            memberCounts      = [ordered]@{ known = $known; nested = $nested; other = $other }
            members           = @($memberDetails | ForEach-Object { ConvertTo-MemberObject -Member $_ })
        }
    }

    $payload = [ordered]@{
        generatedAt = [string]$Summary.GeneratedAt
        summary     = [ordered]@{
            totalGroups   = $Summary.TotalGroups
            failedDomains = @(@($Summary.FailedDomains) | ForEach-Object { [string]$_ })
            warnings      = @(@($Summary.Warnings) | ForEach-Object { [string]$_ })
        }
        groups = @($groups)
    }

    if (-not (Test-Path -LiteralPath $OutputDirectory)) {
        New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
    }

    # -Depth: PS 5.1 defaults to 2, which would truncate members/reasons. 12 is ample.
    $json = $payload | ConvertTo-Json -Depth 12
    Set-Content -LiteralPath (Join-Path $OutputDirectory 'discovery-data.json') -Value $json -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $OutputDirectory 'discovery-data.js') -Value ("window.__DISCOVERY__ = $json;") -Encoding UTF8
}
