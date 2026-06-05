function Write-HtmlReport {
    [CmdletBinding()]
    param([object[]]$Results, [object]$Summary, [Parameter(Mandatory)][string]$Path)

    function Get-HtmlEncoded([string]$Text) {
        if ($null -eq $Text) { return '' }
        [System.Web.HttpUtility]::HtmlEncode($Text)
    }
    # System.Web may not be loaded by default; fall back to manual escaping.
    try { Add-Type -AssemblyName System.Web -ErrorAction Stop } catch { $null = $_ }
    if (-not ('System.Web.HttpUtility' -as [type])) {
        function Get-HtmlEncoded([string]$Text) {
            if ($null -eq $Text) { return '' }
            $Text.Replace('&','&amp;').Replace('<','&lt;').Replace('>','&gt;').Replace('"','&quot;')
        }
    }

    $css = @'
<style>
body{font-family:Segoe UI,Arial,sans-serif;margin:1.5rem;color:#1a1a1a}
h1{font-size:1.4rem} h2{margin-top:1.5rem;border-bottom:1px solid #ddd}
table{border-collapse:collapse;width:100%;margin-bottom:1rem;font-size:.85rem}
th,td{border:1px solid #ccc;padding:4px 6px;text-align:left;vertical-align:top}
th{background:#f2f2f2}
.Confirmed{border-left:5px solid #6f42c1}.High{border-left:5px solid #d73a49}
.Medium{border-left:5px solid #e36209}.Low{border-left:5px solid #6a737d}
.reason{display:inline-block;background:#eef;border-radius:3px;padding:1px 4px;margin:1px;font-size:.75rem}
.summary{background:#f6f8fa;border:1px solid #ddd;padding:.5rem 1rem;border-radius:4px}
</style>
'@

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('<!DOCTYPE html><html><head><meta charset="utf-8"><title>AD Vendor Group Audit</title>')
    [void]$sb.AppendLine($css); [void]$sb.AppendLine('</head><body>')
    [void]$sb.AppendLine('<h1>AD Vendor Group Audit</h1>')
    [void]$sb.AppendLine('<div class="summary">')
    [void]$sb.AppendLine("<div>Generated: $(Get-HtmlEncoded "$($Summary.GeneratedAt)")</div>")
    [void]$sb.AppendLine("<div>Groups reported: $($Summary.TotalGroups)</div>")
    if (@($Summary.FailedDomains).Count) {
        [void]$sb.AppendLine("<div>Failed domains: $(Get-HtmlEncoded ((@($Summary.FailedDomains)) -join ', '))</div>")
    }
    if (@($Summary.Warnings).Count) {
        [void]$sb.AppendLine("<div>Warnings: $(@($Summary.Warnings).Count)</div>")
    }
    [void]$sb.AppendLine('</div>')

    $byDomain = $Results | Group-Object Domain
    foreach ($dg in $byDomain) {
        [void]$sb.AppendLine("<h2>$(Get-HtmlEncoded $dg.Name)</h2>")
        [void]$sb.AppendLine('<table><tr><th>Confidence</th><th>Name</th><th>Owner</th><th>Members</th><th>Member Of</th><th>Description</th><th>Match Reasons</th><th>Scope/Category</th></tr>')
        $ordered = $dg.Group | Sort-Object @{ Expression = {
            switch ($_.Confidence) { 'Confirmed' {0} 'High' {1} 'Medium' {2} 'Low' {3} default {4} } } }, Name
        foreach ($r in $ordered) {
            $reasons = (@($r.Reasons) | ForEach-Object { "<span class='reason'>$(Get-HtmlEncoded "$($_.Pattern): $($_.Value)")</span>" }) -join ' '
            [void]$sb.AppendLine("<tr class='$($r.Confidence)'>")
            [void]$sb.AppendLine("<td>$($r.Confidence) ($($r.Score))</td>")
            [void]$sb.AppendLine("<td>$(Get-HtmlEncoded $r.Name)</td>")
            [void]$sb.AppendLine("<td>$(Get-HtmlEncoded $r.Owner)</td>")
            [void]$sb.AppendLine("<td>$(Get-HtmlEncoded ((@($r.Members)) -join '; '))</td>")
            [void]$sb.AppendLine("<td>$(Get-HtmlEncoded ((@($r.MemberOfDisplay)) -join '; '))</td>")
            [void]$sb.AppendLine("<td>$(Get-HtmlEncoded $r.Description)</td>")
            [void]$sb.AppendLine("<td>$reasons</td>")
            [void]$sb.AppendLine("<td>$(Get-HtmlEncoded "$($r.GroupScope)/$($r.GroupCategory)")</td>")
            [void]$sb.AppendLine('</tr>')
        }
        [void]$sb.AppendLine('</table>')
    }
    [void]$sb.AppendLine('</body></html>')
    Set-Content -LiteralPath $Path -Value $sb.ToString() -Encoding UTF8
}
