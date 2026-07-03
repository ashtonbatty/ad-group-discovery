# Run-log plumbing shared by every layer. Initialize-DiscoveryLog points the log
# at a file for the current run; Write-DiscoveryLog appends timestamped, leveled
# lines there and mirrors them to the verbose stream. With no file initialized it
# degrades to verbose-only, so pure Engine/ functions (and their unit tests) can
# log without any setup.

function Initialize-DiscoveryLog {
    [CmdletBinding()]
    param([string]$Path)
    $script:DiscoveryLogPath = $Path
    if (-not [string]::IsNullOrWhiteSpace($Path)) {
        Set-Content -LiteralPath $Path -Encoding UTF8 -Value (
            "{0} [INFO ] Discovery log started (pid {1}, PowerShell {2})" -f `
            (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff'), $PID, $PSVersionTable.PSVersion)
    }
}

function Write-DiscoveryLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO','DEBUG','WARN')][string]$Level = 'INFO'
    )
    $line = "{0} [{1,-5}] {2}" -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff'), $Level, $Message
    if ($script:DiscoveryLogPath) {
        # Logging must never break discovery: swallow file errors (e.g. a stale
        # path after the output directory was removed) and keep going.
        Add-Content -LiteralPath $script:DiscoveryLogPath -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
    }
    Write-Verbose -Message $line
}
