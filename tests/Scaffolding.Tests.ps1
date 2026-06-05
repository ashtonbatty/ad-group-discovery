BeforeAll { . "$PSScriptRoot/_TestHelpers.ps1" }

Describe 'Scaffolding' {
    It 'has a module manifest that parses' {
        $root = Split-Path -Parent $PSScriptRoot
        $manifest = Join-Path $root 'AdVendorGroupAudit.psd1'
        Test-Path $manifest | Should -BeTrue
        { Import-PowerShellDataFile -Path $manifest } | Should -Not -Throw
    }
}
