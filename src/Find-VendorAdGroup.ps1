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
        [switch]$ResolveMemberDetails,
        [ValidateSet('Low','Medium','High','Confirmed')][string]$MinimumConfidence = 'Low'
    )

    $runTimer = [System.Diagnostics.Stopwatch]::StartNew()
    if (-not (Test-Path -LiteralPath $OutputDirectory)) {
        New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
    }
    Initialize-DiscoveryLog -Path (Join-Path $OutputDirectory 'discovery.log')
    Write-DiscoveryLog ("Run parameters: Formats=[{0}] MinimumConfidence={1} SecurityGroupsOnly={2} ResolveMemberDetails={3} OutputDirectory='{4}'" -f `
        ($Formats -join ','), $MinimumConfidence, [bool]$SecurityGroupsOnly, [bool]$ResolveMemberDetails, $OutputDirectory)

    $inputData = Read-DiscoveryInput -UsersCsv $UsersCsv -DomainsCsv $DomainsCsv -KeywordsCsv $KeywordsCsv `
        -KnownGroupsCsv $KnownGroupsCsv -ExcludeGroupsCsv $ExcludeGroupsCsv

    $domainCount = @($inputData.Domains).Count
    $userCount   = @($inputData.Users).Count
    Write-Host "Querying Active Directory ($domainCount domain(s), $userCount vendor user(s))..."
    $data = Get-AdDiscoveryData -InputData $inputData -Credential $Credential `
        -DomainCredentials $DomainCredentials -SecurityGroupsOnly:$SecurityGroupsOnly `
        -ResolveMemberDetails:$ResolveMemberDetails

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
    $bandCounts = @($selected | Group-Object Confidence | ForEach-Object { "$($_.Name)=$($_.Count)" }) -join ', '
    Write-DiscoveryLog ("Selection complete: {0} group(s) surfaced ({1})" -f @($selected).Count, $(if ($bandCounts) { $bandCounts } else { 'none' }))

    $activeFormats = $Formats | Where-Object { $_ -ne 'Console' }
    if ($activeFormats) { Write-Host "Writing reports ($($activeFormats -join ', '))..." }
    $reportTimer = [System.Diagnostics.Stopwatch]::StartNew()
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
        Write-DiscoveryLog ("Report: CSV set written ({0} group row(s), {1} membership row(s), {2} account row(s))" -f `
            @($selected).Count, @($memberships).Count, @($accounts).Count)
    }
    if ($Formats -contains 'Html') {
        Write-HtmlReport -Results $selected -Summary $summary -Path (Join-Path $OutputDirectory 'vendor-group-discovery.html')
        Write-DiscoveryLog 'Report: HTML written (vendor-group-discovery.html)'
    }
    if ($Formats -contains 'Json') {
        Write-JsonReport -Results $selected -Summary $summary -OutputDirectory $OutputDirectory
        $assetRoot = Join-Path $PSScriptRoot 'Report/assets'
        Copy-Item -LiteralPath (Join-Path $assetRoot 'viewer.html') `
            -Destination (Join-Path $OutputDirectory 'discovery-report.html') -Force
        # The viewer loads Tabulator from sibling files; the report directory must ship as a unit.
        foreach ($asset in 'tabulator.min.js', 'tabulator.min.css') {
            Copy-Item -LiteralPath (Join-Path $assetRoot $asset) `
                -Destination (Join-Path $OutputDirectory $asset) -Force
        }
        Write-DiscoveryLog 'Report: JSON sidecar + interactive viewer written (discovery-report.html + Tabulator assets)'
    }
    if ($Formats -contains 'Console') {
        Write-ConsoleSummary -Results $selected -Summary $summary
    }
    Write-DiscoveryLog ("Reports complete in {0} ms" -f $reportTimer.ElapsedMilliseconds)

    Write-DiscoveryLog ("Run complete in {0:n1} s: {1} group(s), {2} warning(s), {3} failed domain(s)" -f `
        $runTimer.Elapsed.TotalSeconds, @($selected).Count, @($data.Warnings).Count, @($data.FailedDomains).Count)
    Write-Host "Detailed log: $(Join-Path $OutputDirectory 'discovery.log')"

    [pscustomobject]@{ Results = $selected; Summary = $summary }
}
