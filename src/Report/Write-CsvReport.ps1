function Write-CsvReport {
    [CmdletBinding()]
    param(
        [object[]]$Results,
        [Parameter(Mandatory)][string]$Path,
        [string]$MembersPath
    )

    function New-GroupReportKey {
        param([object]$Result)
        "$($Result.Domain)\$($Result.Name)"
    }

    function Get-ResultMemberDetails {
        param([object]$Result)
        $memberDetailsProperty = $Result.PSObject.Properties['MemberDetails']
        if ($memberDetailsProperty) { return @($memberDetailsProperty.Value) }

        $fallback = New-Object System.Collections.Generic.List[object]
        foreach ($member in @($Result.Members)) {
            if ([string]::IsNullOrWhiteSpace($member)) { continue }
            $displayName = [string]$member
            $memberType = 'Other'
            if ($displayName.StartsWith('*')) {
                $memberType = 'Known'
                $displayName = $displayName.Substring(1)
            }
            $fallback.Add([pscustomobject]@{
                MemberType        = $memberType
                SamAccountName    = ''
                DisplayName       = $displayName
                DistinguishedName = ''
            })
        }
        return $fallback.ToArray()
    }

    function Get-MemberSummary {
        param([object[]]$MemberDetails)
        $known = @($MemberDetails | Where-Object { $_.MemberType -eq 'Known' }).Count
        $nested = @($MemberDetails | Where-Object { $_.MemberType -eq 'NestedGroup' }).Count
        $other = @($MemberDetails | Where-Object { $_.MemberType -ne 'Known' -and $_.MemberType -ne 'NestedGroup' }).Count
        [pscustomobject]@{
            KnownMemberCount = $known
            OtherMemberCount = $other
            NestedGroupCount = $nested
        }
    }

    if ([string]::IsNullOrWhiteSpace($MembersPath)) {
        $directory = Split-Path -Parent $Path
        $leaf = Split-Path -Leaf $Path
        $extension = [System.IO.Path]::GetExtension($leaf)
        $stem = [System.IO.Path]::GetFileNameWithoutExtension($leaf)
        $memberLeaf = if ($extension) { "$stem-members$extension" } else { "$leaf-members.csv" }
        $MembersPath = if ([string]::IsNullOrWhiteSpace($directory)) { $memberLeaf } else { Join-Path $directory $memberLeaf }
    }

    $rows = foreach ($r in $Results) {
        $memberDetails = @(Get-ResultMemberDetails -Result $r)
        $memberSummary = Get-MemberSummary -MemberDetails $memberDetails
        [pscustomobject]@{
            GroupKey          = (Protect-CsvCell (New-GroupReportKey -Result $r))
            Domain            = (Protect-CsvCell $r.Domain)
            Name              = (Protect-CsvCell $r.Name)
            Confidence        = (Protect-CsvCell $r.Confidence)
            Score             = $r.Score
            Source            = (Protect-CsvCell $r.Source)
            Description       = (Protect-CsvCell $r.Description)
            Info              = (Protect-CsvCell $r.Info)
            Owner             = (Protect-CsvCell $r.Owner)
            KnownMemberCount  = $memberSummary.KnownMemberCount
            OtherMemberCount  = $memberSummary.OtherMemberCount
            NestedGroupCount  = $memberSummary.NestedGroupCount
            MemberOf          = (Protect-CsvCell (@($r.MemberOfDisplay) -join '; '))
            GroupScope        = (Protect-CsvCell $r.GroupScope)
            GroupCategory     = (Protect-CsvCell $r.GroupCategory)
            Mail              = (Protect-CsvCell $r.Mail)
            AdminCount        = $r.AdminCount
            WhenCreated       = $r.WhenCreated
            WhenChanged       = $r.WhenChanged
            DistinguishedName = (Protect-CsvCell $r.DistinguishedName)
            MatchReasons      = (Protect-CsvCell ((@($r.Reasons) | ForEach-Object { "$($_.Pattern): $($_.Value)" }) -join '; '))
        }
    }
    $memberRows = foreach ($r in $Results) {
        $groupKey = New-GroupReportKey -Result $r
        foreach ($m in @(Get-ResultMemberDetails -Result $r)) {
            [pscustomobject]@{
                GroupKey          = (Protect-CsvCell $groupKey)
                Domain            = (Protect-CsvCell $r.Domain)
                GroupName         = (Protect-CsvCell $r.Name)
                MemberType        = (Protect-CsvCell $m.MemberType)
                SamAccountName    = (Protect-CsvCell $m.SamAccountName)
                DisplayName       = (Protect-CsvCell $m.DisplayName)
                DistinguishedName = (Protect-CsvCell $m.DistinguishedName)
            }
        }
    }
    $rows | Export-Csv -LiteralPath $Path -NoTypeInformation -Encoding UTF8
    $memberRows | Export-Csv -LiteralPath $MembersPath -NoTypeInformation -Encoding UTF8
}
