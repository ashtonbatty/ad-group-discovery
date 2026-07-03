function Read-DiscoveryInput {
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
        $cols = if ($rows.Count -gt 0) {
            @($rows[0].PSObject.Properties.Name)
        } else {
            # No data rows - read the header line directly so column validation still runs.
            $headerLine = Get-Content -LiteralPath $Path -TotalCount 1 -ErrorAction SilentlyContinue
            if ([string]::IsNullOrWhiteSpace($headerLine)) {
                @()
            } else {
                @((($headerLine, $headerLine) | ConvertFrom-Csv | Select-Object -First 1).PSObject.Properties.Name)
            }
        }
        foreach ($c in $Required) {
            if ($cols -notcontains $c) { throw "File '$Path' is missing required column '$c'." }
        }
        return $rows
    }

    $users    = Read-Csv $UsersCsv        @('SamAccountName')
    $domains  = Read-Csv $DomainsCsv      @('Domain')
    $keywords = Read-Csv $KeywordsCsv     @('Keyword')
    $known    = Read-Csv $KnownGroupsCsv  @('Domain','Identity')
    $exclude  = Read-Csv $ExcludeGroupsCsv @('Domain','Identity')

    $activeKeywords = @($keywords | ForEach-Object { $_.Keyword } | Where-Object { $_ -and $_.Trim() })
    Write-DiscoveryLog ("Input parsed: {0} user(s), {1} domain(s), {2} keyword(s), {3} known group(s), {4} exclude entry(ies)" -f `
        $users.Count, $domains.Count, $activeKeywords.Count, $known.Count, $exclude.Count)

    [pscustomobject]@{
        Users         = $users
        Domains       = $domains
        Keywords      = $activeKeywords
        KnownGroups   = $known
        ExcludeGroups = $exclude
    }
}
