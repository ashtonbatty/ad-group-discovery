function Write-CsvReport {
    [CmdletBinding()]
    param([object[]]$Results, [Parameter(Mandatory)][string]$Path)
    $rows = foreach ($r in $Results) {
        [pscustomobject]@{
            Domain            = $r.Domain
            Name              = $r.Name
            Confidence        = $r.Confidence
            Score             = $r.Score
            Source            = $r.Source
            Description       = $r.Description
            Info              = $r.Info
            Owner             = $r.Owner
            Members           = (@($r.Members) -join '; ')
            MemberOf          = (@($r.MemberOfDisplay) -join '; ')
            GroupScope        = $r.GroupScope
            GroupCategory     = $r.GroupCategory
            Mail              = $r.Mail
            AdminCount        = $r.AdminCount
            WhenCreated       = $r.WhenCreated
            WhenChanged       = $r.WhenChanged
            DistinguishedName = $r.DistinguishedName
            MatchReasons      = ((@($r.Reasons) | ForEach-Object { "$($_.Pattern): $($_.Value)" }) -join '; ')
        }
    }
    $rows | Export-Csv -LiteralPath $Path -NoTypeInformation -Encoding UTF8
}
