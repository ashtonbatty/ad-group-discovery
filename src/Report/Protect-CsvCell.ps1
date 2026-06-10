function Protect-CsvCell {
    [CmdletBinding()]
    param([object]$Value)
    if ($null -eq $Value) { return $Value }
    $s = [string]$Value
    # Neutralize leading formula triggers: = + - @ TAB LF CR
    if ($s -match '^[=+\-@\t\n\r]') { $s = "'" + $s }
    return $s
}
