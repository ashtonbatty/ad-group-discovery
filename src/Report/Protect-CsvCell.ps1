function Protect-CsvCell {
    [CmdletBinding()]
    param([object]$Value)
    if ($null -eq $Value) { return $Value }
    $s = [string]$Value
    if ($s.Length -gt 0) {
        $first = $s[0]
        # Neutralize leading formula triggers: = + - @ TAB CR
        if ($first -eq '=' -or $first -eq '+' -or $first -eq '-' -or $first -eq '@' -or $first -eq [char]9 -or $first -eq [char]13) {
            $s = "'" + $s
        }
    }
    return $s
}
