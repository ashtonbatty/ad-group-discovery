function Find-VendorAdGroup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$UsersCsv,
        [Parameter(Mandatory)][string]$DomainsCsv,
        [Parameter(Mandatory)][string]$KeywordsCsv,
        [Parameter(Mandatory)][string]$KnownGroupsCsv,
        [Parameter(Mandatory)][string]$ExcludeGroupsCsv,
        [Parameter(Mandatory)][string]$OutputDirectory,
        [ValidateSet('Csv','Html','Console','Json')][string[]]$Formats = @('Csv','Html','Console','Json'),
        [System.Management.Automation.PSCredential]$Credential,
        [hashtable]$DomainCredentials,
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
    $data = Get-AdDiscoveryData -InputData $inputData -Credential $Credential `
        -DomainCredentials $DomainCredentials -SecurityGroupsOnly:$SecurityGroupsOnly

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
        Write-CsvReport -Results $selected `
            -Path (Join-Path $OutputDirectory 'vendor-group-discovery.csv') `
            -MembersPath (Join-Path $OutputDirectory 'vendor-group-discovery-members.csv')

        $memberships = Get-VendorUserMemberships -VendorUsers $data.VendorUsers -Groups $groups
        Write-UserMembershipReport -Rows $memberships `
            -Path (Join-Path $OutputDirectory 'vendor-user-memberships.csv')

        $accounts = Get-VendorUserAccounts -VendorUsers $data.VendorUsers
        Write-UserAccountReport -Rows $accounts `
            -Path (Join-Path $OutputDirectory 'vendor-user-accounts.csv')
    }
    if ($Formats -contains 'Html') {
        Write-HtmlReport -Results $selected -Summary $summary -Path (Join-Path $OutputDirectory 'vendor-group-discovery.html')
    }
    if ($Formats -contains 'Json') {
        Write-JsonReport -Results $selected -Summary $summary -OutputDirectory $OutputDirectory
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Report/assets/viewer.html') `
            -Destination (Join-Path $OutputDirectory 'discovery-report.html') -Force
    }
    if ($Formats -contains 'Console') {
        Write-ConsoleSummary -Results $selected -Summary $summary
    }

    [pscustomobject]@{ Results = $selected; Summary = $summary }
}
