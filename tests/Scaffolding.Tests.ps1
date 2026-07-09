BeforeAll { . "$PSScriptRoot/_TestHelpers.ps1" }

Describe 'Scaffolding' {
    It 'has a module manifest that parses' {
        $root = Split-Path -Parent $PSScriptRoot
        $manifest = Join-Path $root 'VendorAdGroupDiscovery.psd1'
        Test-Path $manifest | Should -BeTrue
        { Import-PowerShellDataFile -Path $manifest } | Should -Not -Throw
    }
    It 'declares every module Find-VendorAdGroup parameter on the root runner' {
        # The runner forwards $PSBoundParameters, so a module parameter missing
        # from the runner's explicit param block is silently unusable from the CLI.
        $root = Split-Path -Parent $PSScriptRoot
        $runnerAst = [System.Management.Automation.Language.Parser]::ParseFile(
            (Join-Path $root 'Find-VendorAdGroup.ps1'), [ref]$null, [ref]$null)
        $runnerParams = @($runnerAst.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
        $common = [System.Management.Automation.PSCmdlet]::CommonParameters
        $moduleParams = @((Get-Command Find-VendorAdGroup).Parameters.Keys | Where-Object { $_ -notin $common })
        foreach ($p in $moduleParams) { $runnerParams | Should -Contain $p }
    }
}
