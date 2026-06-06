function Find-VendorAdGroup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$UsersCsv,
        [Parameter(Mandatory)][string]$DomainsCsv,
        [Parameter(Mandatory)][string]$KeywordsCsv,
        [Parameter(Mandatory)][string]$KnownGroupsCsv,
        [Parameter(Mandatory)][string]$ExcludeGroupsCsv,
        [Parameter(Mandatory)][string]$OutputDirectory,
        [ValidateSet('Csv','Html','Console')][string[]]$Formats = @('Csv','Html','Console'),
        [System.Management.Automation.PSCredential]$Credential,
        [int]$MaxIterations = 25,
        [switch]$SecurityGroupsOnly,
        [ValidateSet('Low','Medium','High','Confirmed')][string]$MinimumConfidence = 'Low'
    )

    $inputData = Read-DiscoveryInput -UsersCsv $UsersCsv -DomainsCsv $DomainsCsv -KeywordsCsv $KeywordsCsv `
        -KnownGroupsCsv $KnownGroupsCsv -ExcludeGroupsCsv $ExcludeGroupsCsv

    $knownKeys = @{}
    foreach ($k in $inputData.KnownGroups) { $knownKeys[(Get-GroupLookupKey -Domain $k.Domain -Identity $k.Identity)] = $true }
    $excludeKeys = @{}
    foreach ($e in $inputData.ExcludeGroups) { $excludeKeys[(Get-GroupLookupKey -Domain $e.Domain -Identity $e.Identity)] = $true }

    if (-not (Test-Path -LiteralPath $OutputDirectory)) {
        New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
    }

    $data = Get-AdDiscoveryData -InputData $inputData -Credential $Credential

    $groups = $data.Groups
    if ($SecurityGroupsOnly) { $groups = @($groups | Where-Object { "$($_.GroupCategory)" -eq 'Security' }) }

    $candidates = Find-CandidateGroups -Groups $groups -Keywords $inputData.Keywords `
        -VendorUsers $data.VendorUsers -KnownKeys $knownKeys -ExcludeKeys $excludeKeys
    $candidates = Expand-VendorGroupClosure -Results $candidates -MaxIterations $MaxIterations
    $selected   = Select-DiscoveryResults -Results $candidates -MinimumConfidence $MinimumConfidence
    $selected   = Resolve-ResultDisplay -Results $selected -DnIndex $data.DnIndex -VendorUsers $data.VendorUsers
    $rank       = Get-ConfidenceRank
    $selected   = @($selected | Sort-Object @{ Expression = { $rank[$_.Confidence] }; Descending = $true }, Domain, Name)

    $summary = [pscustomobject]@{
        TotalGroups   = @($selected).Count
        FailedDomains = $data.FailedDomains
        Warnings      = $data.Warnings
        GeneratedAt   = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    }

    if ($Formats -contains 'Csv') {
        Write-CsvReport -Results $selected -Path (Join-Path $OutputDirectory 'vendor-group-discovery.csv')
    }
    if ($Formats -contains 'Html') {
        Write-HtmlReport -Results $selected -Summary $summary -Path (Join-Path $OutputDirectory 'vendor-group-discovery.html')
    }
    if ($Formats -contains 'Console') {
        Write-ConsoleSummary -Results $selected -Summary $summary
    }

    [pscustomobject]@{ Results = $selected; Summary = $summary }
}
