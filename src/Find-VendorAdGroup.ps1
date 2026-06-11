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
        [switch]$SecurityGroupsOnly,
        [ValidateSet('Low','Medium','High','Confirmed')][string]$MinimumConfidence = 'Low'
    )

    $inputData = Read-DiscoveryInput -UsersCsv $UsersCsv -DomainsCsv $DomainsCsv -KeywordsCsv $KeywordsCsv `
        -KnownGroupsCsv $KnownGroupsCsv -ExcludeGroupsCsv $ExcludeGroupsCsv

    if (-not (Test-Path -LiteralPath $OutputDirectory)) {
        New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
    }

    $domainCount = @($inputData.Domains).Count
    $userCount   = @($inputData.Users).Count
    Write-Host "Querying Active Directory ($domainCount domain(s), $userCount vendor user(s))..."
    $data = Get-AdDiscoveryData -InputData $inputData -Credential $Credential

    $groups = $data.Groups
    if ($SecurityGroupsOnly) { $groups = @($groups | Where-Object { "$($_.GroupCategory)" -eq 'Security' }) }

    Write-Host "Running discovery engine over $(@($groups).Count) group(s)..."
    $selected = Invoke-DiscoveryEngine -Groups $groups -InputData $inputData `
        -VendorUsers $data.VendorUsers -DnIndex $data.DnIndex `
        -MinimumConfidence $MinimumConfidence

    $summary = [pscustomobject]@{
        TotalGroups   = @($selected).Count
        FailedDomains = $data.FailedDomains
        Warnings      = $data.Warnings
        GeneratedAt   = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    }

    $activeFormats = $Formats | Where-Object { $_ -ne 'Console' }
    if ($activeFormats) { Write-Host "Writing reports ($($activeFormats -join ', '))..." }
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
