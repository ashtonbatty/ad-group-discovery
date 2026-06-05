function Write-CsvReport {
    [CmdletBinding()]
    param([object[]]$Results, [Parameter(Mandatory)][string]$Path)
    $rows = foreach ($r in $Results) {
        [pscustomobject]@{
            Domain            = (Protect-CsvCell $r.Domain)
            Name              = (Protect-CsvCell $r.Name)
            Confidence        = (Protect-CsvCell $r.Confidence)
            Score             = $r.Score
            Source            = (Protect-CsvCell $r.Source)
            Description       = (Protect-CsvCell $r.Description)
            Info              = (Protect-CsvCell $r.Info)
            Owner             = (Protect-CsvCell $r.Owner)
            Members           = (Protect-CsvCell (@($r.Members) -join '; '))
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
    $rows | Export-Csv -LiteralPath $Path -NoTypeInformation -Encoding UTF8
}
