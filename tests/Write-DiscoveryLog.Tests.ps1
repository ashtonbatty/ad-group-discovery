BeforeAll {
    . "$PSScriptRoot/_TestHelpers.ps1"
    $script:tmp = New-TestTempDir -Prefix 'log'
}
AfterAll { Remove-Item -Recurse -Force $script:tmp -ErrorAction SilentlyContinue }

Describe 'Write-DiscoveryLog' {
    It 'is a no-op when no log file is initialized' {
        Initialize-DiscoveryLog -Path ''
        { Write-DiscoveryLog -Message 'nowhere to go' } | Should -Not -Throw
    }

    It 'writes timestamped, leveled lines to the initialized log file' {
        $log = Join-Path $tmp 'run.log'
        Initialize-DiscoveryLog -Path $log
        Write-DiscoveryLog -Message 'phase started'
        Write-DiscoveryLog -Level DEBUG -Message 'batch detail'
        Write-DiscoveryLog -Level WARN -Message 'something failed'

        $lines = Get-Content $log
        $lines[0] | Should -Match 'Discovery log started'
        foreach ($line in $lines) {
            $line | Should -Match '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3} \[(INFO |DEBUG|WARN )\] '
        }
        ($lines -match '\[INFO \] phase started')    | Should -Not -BeNullOrEmpty
        ($lines -match '\[DEBUG\] batch detail')     | Should -Not -BeNullOrEmpty
        ($lines -match '\[WARN \] something failed') | Should -Not -BeNullOrEmpty
    }

    It 'starts a fresh log on re-initialization' {
        $log = Join-Path $tmp 'rerun.log'
        Initialize-DiscoveryLog -Path $log
        Write-DiscoveryLog -Message 'first run'
        Initialize-DiscoveryLog -Path $log
        Write-DiscoveryLog -Message 'second run'

        $content = Get-Content $log -Raw
        $content | Should -Not -Match 'first run'
        $content | Should -Match 'second run'
    }

    It 'does not throw when the log directory has been removed' {
        $goneDir = Join-Path $tmp 'gone'
        New-Item -ItemType Directory -Path $goneDir | Out-Null
        Initialize-DiscoveryLog -Path (Join-Path $goneDir 'orphan.log')
        Remove-Item -Recurse -Force $goneDir
        { Write-DiscoveryLog -Message 'writes into the void' } | Should -Not -Throw
        Initialize-DiscoveryLog -Path ''
    }
}
