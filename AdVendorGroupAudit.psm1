# Dot-source every function under src/, then export the public entry point.
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Get-ChildItem -Path (Join-Path $here 'src') -Recurse -Filter '*.ps1' -ErrorAction SilentlyContinue |
    ForEach-Object { . $_.FullName }
Export-ModuleMember -Function 'Invoke-AdVendorGroupAudit'
