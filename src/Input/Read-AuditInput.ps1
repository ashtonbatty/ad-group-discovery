function Read-AuditInput {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$UsersCsv,
        [Parameter(Mandatory)][string]$DomainsCsv,
        [Parameter(Mandatory)][string]$KeywordsCsv,
        [Parameter(Mandatory)][string]$KnownGroupsCsv,
        [Parameter(Mandatory)][string]$ExcludeGroupsCsv
    )

    function Read-Csv([string]$Path, [string[]]$Required) {
        if (-not (Test-Path -LiteralPath $Path)) { throw "Input file not found: $Path" }
        $rows = @(Import-Csv -LiteralPath $Path)
        if ($rows.Count -gt 0) {
            $cols = $rows[0].PSObject.Properties.Name
            foreach ($c in $Required) {
                if ($cols -notcontains $c) { throw "File '$Path' is missing required column '$c'." }
            }
        }
        return $rows
    }

    $users    = Read-Csv $UsersCsv        @('SamAccountName')
    $domains  = Read-Csv $DomainsCsv      @('Domain')
    $keywords = Read-Csv $KeywordsCsv     @('Keyword')
    $known    = Read-Csv $KnownGroupsCsv  @('Domain','Identity')
    $exclude  = Read-Csv $ExcludeGroupsCsv @('Domain','Identity')

    [pscustomobject]@{
        Users         = $users
        Domains       = $domains
        Keywords      = @($keywords | ForEach-Object { $_.Keyword } | Where-Object { $_ -and $_.Trim() })
        KnownGroups   = $known
        ExcludeGroups = $exclude
    }
}
