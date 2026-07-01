function Write-UserMembershipReport {
    # Normalized user->group membership CSV. Group metadata is
    # attacker-influenceable, so every cell is formula-injection hardened.
    [CmdletBinding()]
    param([object[]]$Rows, [Parameter(Mandatory)][string]$Path)
    $out = foreach ($r in @($Rows)) {
        [pscustomobject]@{
            UserDomain         = (Protect-CsvCell $r.UserDomain)
            UserSamAccountName = (Protect-CsvCell $r.UserSamAccountName)
            UserDisplayName    = (Protect-CsvCell $r.UserDisplayName)
            GroupDomain        = (Protect-CsvCell $r.GroupDomain)
            GroupName          = (Protect-CsvCell $r.GroupName)
        }
    }
    $out | Export-Csv -LiteralPath $Path -NoTypeInformation -Encoding UTF8
}
