function Write-UserAccountReport {
    # Per-user account-audit CSV. User attributes (e.g. Description) are
    # attacker-influenceable, so every cell is formula-injection hardened.
    [CmdletBinding()]
    param([object[]]$Rows, [Parameter(Mandatory)][string]$Path)
    $out = foreach ($r in @($Rows)) {
        [pscustomobject]@{
            UserDomain            = (Protect-CsvCell $r.UserDomain)
            UserSamAccountName    = (Protect-CsvCell $r.UserSamAccountName)
            UserDisplayName       = (Protect-CsvCell $r.UserDisplayName)
            Enabled               = (Protect-CsvCell $r.Enabled)
            LockedOut             = (Protect-CsvCell $r.LockedOut)
            Description           = (Protect-CsvCell $r.Description)
            AccountExpirationDate = (Protect-CsvCell $r.AccountExpirationDate)
            LastLogonDate         = (Protect-CsvCell $r.LastLogonDate)
            PasswordLastSet       = (Protect-CsvCell $r.PasswordLastSet)
            PasswordExpiry        = (Protect-CsvCell $r.PasswordExpiry)
            PasswordNeverExpires  = (Protect-CsvCell $r.PasswordNeverExpires)
            BadLogonCount         = (Protect-CsvCell $r.BadLogonCount)
        }
    }
    $out | Export-Csv -LiteralPath $Path -NoTypeInformation -Encoding UTF8
}
