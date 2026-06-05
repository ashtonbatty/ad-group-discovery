# Dot-source all source functions so tests can call them directly (no module import needed).
$root = Split-Path -Parent $PSScriptRoot
Get-ChildItem -Path (Join-Path $root 'src') -Recurse -Filter '*.ps1' -ErrorAction SilentlyContinue |
    ForEach-Object { . $_.FullName }

# Stub AD cmdlets so Pester Mock can intercept them on non-Windows / no-AD test runners.
if (-not (Get-Command Get-ADGroup  -ErrorAction SilentlyContinue)) {
    function Get-ADGroup  { [CmdletBinding()] param([Parameter(ValueFromRemainingArguments)]$RemainingArgs) }
}
if (-not (Get-Command Get-ADUser   -ErrorAction SilentlyContinue)) {
    function Get-ADUser   { [CmdletBinding()] param([Parameter(ValueFromRemainingArguments)]$RemainingArgs) }
}
