function Get-VendorUserAccounts {
    # Pure projection: one account-audit row per vendor user. Date fields are
    # formatted uniformly; PasswordExpiry is derived from the raw
    # msDS-UserPasswordExpiryComputed FileTime carried as PasswordExpiryComputed.
    [CmdletBinding()]
    param([object[]]$VendorUsers)

    function Format-AccountDate {
        param($Value)
        if ($null -eq $Value) { return '' }
        if ($Value -is [datetime]) { return $Value.ToString('yyyy-MM-dd HH:mm:ss') }
        return [string]$Value
    }

    function Convert-PasswordExpiry {
        param($Raw)
        if ($null -eq $Raw) { return '' }
        $val = [int64]0
        if (-not [int64]::TryParse([string]$Raw, [ref]$val)) { return '' }
        # 0 = expired / must change at next logon; Int64.MaxValue = never
        # (FromFileTime throws on it). Both render as blank.
        if ($val -le 0 -or $val -eq [int64]::MaxValue) { return '' }
        try { return [datetime]::FromFileTime($val).ToString('yyyy-MM-dd HH:mm:ss') } catch { return '' }
    }

    foreach ($user in @($VendorUsers)) {
        [pscustomobject]@{
            UserDomain            = $user.Domain
            UserSamAccountName    = $user.SamAccountName
            UserDisplayName       = $user.DisplayName
            Enabled               = $user.Enabled
            LockedOut             = $user.LockedOut
            Description           = $user.Description
            AccountExpirationDate = (Format-AccountDate $user.AccountExpirationDate)
            LastLogonDate         = (Format-AccountDate $user.LastLogonDate)
            PasswordLastSet       = (Format-AccountDate $user.PasswordLastSet)
            PasswordExpiry        = (Convert-PasswordExpiry $user.PasswordExpiryComputed)
            PasswordNeverExpires  = $user.PasswordNeverExpires
            BadLogonCount         = $user.BadLogonCount
        }
    }
}
