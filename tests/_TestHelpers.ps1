# Dot-source all source functions so tests can call them directly (no module import needed).
$root = Split-Path -Parent $PSScriptRoot
Get-ChildItem -Path (Join-Path $root 'src') -Recurse -Filter '*.ps1' -ErrorAction SilentlyContinue |
    ForEach-Object { . $_.FullName }
