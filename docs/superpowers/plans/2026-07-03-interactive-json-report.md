# Interactive JSON-backed Discovery Report Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an alternative, interactive HTML report that loads discovery results from an external JS/JSON sidecar and presents them with sort, filter, group-by, group-collapse, and usability extras.

**Architecture:** A new pure PowerShell writer (`Write-JsonReport`) emits `discovery-data.js` (`window.__DISCOVERY__ = {...}`) plus a bare `discovery-data.json`. A static, self-contained `viewer.html` asset (Tabulator + all JS/CSS inlined) is copied to the output dir as `discovery-report.html`; it loads the sidecar via a `<script>` tag so a double-clicked `file://` page works with no server. All existing reports are untouched.

**Tech Stack:** Windows PowerShell 5.1 (runtime), Pester 5 (tests), Tabulator (vendored, inlined JS grid library), plain HTML/CSS/JS.

## Global Constraints

- **Target Windows PowerShell 5.1** — no syntax/cmdlets unavailable in 5.1. In particular `ConvertTo-Json` defaults to `-Depth 2`; the nested payload REQUIRES an explicit high `-Depth`.
- **AD boundary stays thin** — only `Get-AdDiscoveryData` calls AD cmdlets. The new writer is a pure function over the discovery result objects; no AD calls.
- **Report output is security-sensitive** — group metadata is attacker-influenceable. The JSON writer emits data as-is (JSON is injection-safe). The viewer MUST render every data-bearing field as **text, not HTML**: rely on Tabulator's default cell escaping, never apply the `html` formatter to data columns, and build the row-detail panel with `textContent`/DOM APIs, never `innerHTML` with data.
- **No CDN at runtime** — the report must work offline on an RSAT box. Tabulator's JS + CSS are inlined into `viewer.html`; nothing is fetched at view time except the sibling `discovery-data.js`.
- **File names** (in the output directory): `discovery-data.js`, `discovery-data.json`, `discovery-report.html`.
- **Conventions** — new source function lives under `src/Report/`; it gets a matching `tests/<Name>.Tests.ps1`; end-to-end behavior gets a `Fixture.Tests.ps1` assertion. Tests dot-source `src/` via `tests/_TestHelpers.ps1`.

---

## File Structure

- **Create** `src/Report/Write-JsonReport.ps1` — pure writer: shape results → payload; write `discovery-data.js` + `discovery-data.json`.
- **Create** `src/Report/assets/viewer.html` — static, self-contained interactive report (Tabulator inlined). Not a `.ps1`, so the module's recursive dot-source ignores it.
- **Create** `tests/Write-JsonReport.Tests.ps1` — unit tests for the writer.
- **Create** `tests/fixtures/Export-FixtureJson.ps1` — dev helper: run engine over the fixture and write real sidecar files, for eyeballing/driving the viewer (mirrors `Export-FixtureHtml.ps1`).
- **Modify** `src/Find-VendorAdGroup.ps1` — add `'Json'` to `-Formats` ValidateSet and default; wire the writer + viewer copy.
- **Modify** `Find-VendorAdGroup.ps1` (repo-root runner) — add `'Json'` to its `-Formats` ValidateSet so the bound param forwards.
- **Modify** `tests/Find-VendorAdGroup.Tests.ps1` — assert the `Json` format produces the three files.
- **Modify** `tests/Fixture.Tests.ps1` — assert an end-to-end fixture run yields a valid sidecar payload.
- **Modify** `README.md`, `CLAUDE.md` — document the new `Json` format and interactive report.

---

### Task 1: `Write-JsonReport` writer

**Files:**
- Create: `src/Report/Write-JsonReport.ps1`
- Test: `tests/Write-JsonReport.Tests.ps1`

**Interfaces:**
- Consumes: engine result objects (fields `Domain`, `Name`, `Confidence`, `Score`, `Source`, `Description`, `Info`, `Owner`, `MemberOfDisplay[]`, `GroupScope`, `GroupCategory`, `Mail`, `AdminCount`, `WhenCreated`, `WhenChanged`, `DistinguishedName`, `Reasons[]` with `Pattern`/`Value`, `MemberDetails[]` with `MemberType`/`SamAccountName`/`DisplayName`/`DistinguishedName`) and a `$Summary` with `TotalGroups`, `FailedDomains`, `Warnings`, `GeneratedAt`.
- Produces: `Write-JsonReport -Results <object[]> -Summary <object> -OutputDirectory <string>`. Writes `discovery-data.json` and `discovery-data.js` into `$OutputDirectory`. No return value.

- [ ] **Step 1: Write the failing test**

Create `tests/Write-JsonReport.Tests.ps1`:

```powershell
BeforeAll {
    . "$PSScriptRoot/_TestHelpers.ps1"
    $script:tmp = New-TestTempDir -Prefix 'json'
    $script:results = @(
        [pscustomobject]@{
            Domain='corp'; Name='Acme Admins'; Confidence='High'; Score=3
            Source='Discovered'; Description='=cmd|calc'; Info='note'; Owner='John Smith'
            MemberOfDisplay=@('Parent Group'); GroupScope='Global'; GroupCategory='Security'
            Mail=$null; AdminCount=1; WhenCreated='2020'; WhenChanged='2021'
            DistinguishedName='CN=Acme Admins,DC=c'
            Reasons=@([pscustomobject]@{ Pattern='NameKeyword'; Value='Acme' })
            MemberDetails=@(
                [pscustomobject]@{ MemberType='Known';       SamAccountName='jsmith'; DisplayName='John Smith'; DistinguishedName='CN=John Smith,DC=c' }
                [pscustomobject]@{ MemberType='NestedGroup'; SamAccountName='';       DisplayName='Sub Group';  DistinguishedName='CN=Sub,DC=c' }
                [pscustomobject]@{ MemberType='Other';       SamAccountName='bob';    DisplayName='Bob';        DistinguishedName='CN=Bob,DC=c' }
            )
        }
    )
    $script:summary = [pscustomobject]@{ TotalGroups=1; FailedDomains=@(); Warnings=@('watch out'); GeneratedAt='2026-07-03 10:00:00' }
    Write-JsonReport -Results $script:results -Summary $script:summary -OutputDirectory $script:tmp
    $script:jsonPath = Join-Path $script:tmp 'discovery-data.json'
    $script:jsPath   = Join-Path $script:tmp 'discovery-data.js'
}
AfterAll { Remove-Item -Recurse -Force $script:tmp -ErrorAction SilentlyContinue }

Describe 'Write-JsonReport' {
    It 'writes both the .js and .json sidecar files' {
        Test-Path $script:jsonPath | Should -BeTrue
        Test-Path $script:jsPath   | Should -BeTrue
    }
    It 'wraps the payload in the window.__DISCOVERY__ global in the .js file' {
        (Get-Content $script:jsPath -Raw) | Should -Match 'window\.__DISCOVERY__ ='
    }
    It 'round-trips a nested payload preserving members and reasons' {
        $data = Get-Content $script:jsonPath -Raw | ConvertFrom-Json
        $data.summary.totalGroups | Should -Be 1
        $g = $data.groups[0]
        $g.name | Should -Be 'Acme Admins'
        $g.confidence | Should -Be 'High'
        $g.reasons[0].pattern | Should -Be 'NameKeyword'
        @($g.members).Count | Should -Be 3
        $g.memberCounts.known  | Should -Be 1
        $g.memberCounts.nested | Should -Be 1
        $g.memberCounts.other  | Should -Be 1
        @($g.memberOf) | Should -Contain 'Parent Group'
    }
    It 'does not apply CSV injection hardening to values' {
        $data = Get-Content $script:jsonPath -Raw | ConvertFrom-Json
        # Description keeps its leading '=' with no apostrophe/tab prefix (that is a CSV-only concern).
        $data.groups[0].description | Should -Be '=cmd|calc'
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path ./tests/Write-JsonReport.Tests.ps1 -Output Detailed"`
Expected: FAIL — `Write-JsonReport` is not recognized (command not found in BeforeAll).

- [ ] **Step 3: Write minimal implementation**

Create `src/Report/Write-JsonReport.ps1`:

```powershell
function Write-JsonReport {
    # Pure writer: shapes engine results into a plain payload and emits two sidecar
    # files next to the interactive viewer. No CSV-style injection hardening -- JSON is
    # inherently injection-safe; the viewer escapes at render time.
    [CmdletBinding()]
    param(
        [object[]]$Results,
        [Parameter(Mandatory)][object]$Summary,
        [Parameter(Mandatory)][string]$OutputDirectory
    )

    function ConvertTo-MemberObject {
        param([object]$Member)
        [ordered]@{
            memberType        = [string]$Member.MemberType
            samAccountName    = [string]$Member.SamAccountName
            displayName       = [string]$Member.DisplayName
            distinguishedName = [string]$Member.DistinguishedName
        }
    }

    $groups = foreach ($r in $Results) {
        $memberDetails = @($r.MemberDetails)
        $known  = @($memberDetails | Where-Object { $_.MemberType -eq 'Known' }).Count
        $nested = @($memberDetails | Where-Object { $_.MemberType -eq 'NestedGroup' }).Count
        $other  = @($memberDetails | Where-Object { $_.MemberType -ne 'Known' -and $_.MemberType -ne 'NestedGroup' }).Count
        [ordered]@{
            domain            = [string]$r.Domain
            name              = [string]$r.Name
            confidence        = [string]$r.Confidence
            score             = $r.Score
            source            = [string]$r.Source
            description       = [string]$r.Description
            info              = [string]$r.Info
            owner             = [string]$r.Owner
            memberOf          = @(@($r.MemberOfDisplay) | ForEach-Object { [string]$_ })
            groupScope        = [string]$r.GroupScope
            groupCategory     = [string]$r.GroupCategory
            mail              = [string]$r.Mail
            adminCount        = $r.AdminCount
            whenCreated       = [string]$r.WhenCreated
            whenChanged       = [string]$r.WhenChanged
            distinguishedName = [string]$r.DistinguishedName
            reasons           = @(@($r.Reasons) | ForEach-Object { [ordered]@{ pattern = [string]$_.Pattern; value = [string]$_.Value } })
            memberCounts      = [ordered]@{ known = $known; nested = $nested; other = $other }
            members           = @($memberDetails | ForEach-Object { ConvertTo-MemberObject -Member $_ })
        }
    }

    $payload = [ordered]@{
        generatedAt = [string]$Summary.GeneratedAt
        summary     = [ordered]@{
            totalGroups   = $Summary.TotalGroups
            failedDomains = @(@($Summary.FailedDomains) | ForEach-Object { [string]$_ })
            warnings      = @(@($Summary.Warnings) | ForEach-Object { [string]$_ })
        }
        groups = @($groups)
    }

    if (-not (Test-Path -LiteralPath $OutputDirectory)) {
        New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
    }

    # -Depth: PS 5.1 defaults to 2, which would truncate members/reasons. 12 is ample.
    $json = $payload | ConvertTo-Json -Depth 12
    Set-Content -LiteralPath (Join-Path $OutputDirectory 'discovery-data.json') -Value $json -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $OutputDirectory 'discovery-data.js') -Value ("window.__DISCOVERY__ = $json;") -Encoding UTF8
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path ./tests/Write-JsonReport.Tests.ps1 -Output Detailed"`
Expected: PASS (4 tests).

- [ ] **Step 5: Lint**

Run: `pwsh -NoProfile -Command "Invoke-ScriptAnalyzer -Path ./src/Report/Write-JsonReport.ps1 -Settings ./PSScriptAnalyzerSettings.psd1"`
Expected: no errors.

- [ ] **Step 6: Commit**

```bash
git add src/Report/Write-JsonReport.ps1 tests/Write-JsonReport.Tests.ps1
git commit -m "feat: add Write-JsonReport sidecar writer for interactive report"
```

---

### Task 2: The interactive `viewer.html` asset

**Files:**
- Create: `src/Report/assets/viewer.html`
- Create: `tests/fixtures/Export-FixtureJson.ps1`

**Interfaces:**
- Consumes: `window.__DISCOVERY__` global (the payload shape produced by Task 1's `Write-JsonReport`), loaded via `<script src="discovery-data.js">`.
- Produces: a self-contained HTML page. No PowerShell interface; validated by driving it in a browser.

> **Design note:** Before writing the page, load the `frontend-design` skill for aesthetic direction (clean, intentional, not templated-default). Keep everything inline — this file is opened from `file://` with no network.

- [ ] **Step 1: Vendor the Tabulator library**

Download Tabulator's minified JS and CSS (pin a specific 6.x; record the exact version in an HTML comment). From a machine with network access:

```bash
mkdir -p /tmp/tabulator
curl -fsSL https://unpkg.com/tabulator-tables@6.3.1/dist/js/tabulator.min.js -o /tmp/tabulator/tabulator.min.js
curl -fsSL https://unpkg.com/tabulator-tables@6.3.1/dist/css/tabulator.min.css -o /tmp/tabulator/tabulator.min.css
```

If 6.3.1 is unavailable, use the latest 6.x and record that version. These two files get inlined verbatim into `viewer.html` in Step 2 (JS inside a `<script>` tag, CSS inside a `<style>` tag).

- [ ] **Step 2: Build `src/Report/assets/viewer.html`**

Create a self-contained page with this structure. Inline the Tabulator CSS/JS from Step 1 where marked. Requirements the code MUST satisfy:

- **Header strip:** title ("AD Vendor Group Discovery"), `generatedAt`, `summary.totalGroups`; if `summary.failedDomains` or `summary.warnings` are non-empty, a visible banner listing them (rendered via `textContent`).
- **Toolbar:**
  - Global search `<input>` — on input, applies a Tabulator global filter across visible columns.
  - "Group by" `<select>` — options: Domain (default/selected), Confidence, GroupScope, GroupCategory, Source, None. On change, call `table.setGroupBy(field)` (or `false` for None).
  - "Collapse all" / "Expand all" buttons — iterate groups and toggle.
  - "Columns" control — Tabulator's built-in column menu (`headerMenu`) or a custom toggle list; must show/hide the optional columns.
  - "Export CSV" button — `table.download("csv", "discovery-filtered.csv")` (exports current filtered/sorted view).
- **Grid (`Tabulator`):**
  - `layout:"fitDataStretch"`, `movableColumns:true`, `groupBy:"domain"`, `height:"100%"`, pagination off (or `paginationSize` large) so grouping/collapse works over the whole set.
  - Group headers show the group value and member count, e.g. `` (group, count) => `${group.getKey()}  (${count})` ``, built as a string of literal text only (no data interpolated as HTML).
  - Columns (all `headerFilter` + sortable):
    - Confidence — custom `formatter` that prepends a colored band swatch built with `document.createElement` and sets the label via `textContent`; `headerFilter:"list"` with values Confirmed/High/Medium/Low; `sorter` is a custom function ranking Confirmed(3) > High(2) > Medium(1) > Low(0).
    - Score — `headerFilter:"number"`, `headerFilterFunc:">="`, numeric sorter.
    - Name, Owner, Description — plain columns, `headerFilter:"input"`. **No `formatter:"html"`.**
    - Members — `#` column showing `known/nested/other` from `memberCounts`, via a formatter that returns a text string.
    - Member Of — joins `memberOf` with `; ` as text.
    - Scope/Category — text `groupScope/groupCategory`.
    - Hidden by default (`visible:false`): Info, Mail, AdminCount, WhenCreated, WhenChanged, DistinguishedName.
  - **Row detail:** `rowClick` toggles an expandable detail row/panel built entirely with DOM APIs (`createElement`, `textContent`) — never `innerHTML` with data. Shows: full member list (`displayName · samAccountName · memberType · distinguishedName`), full reasons (`pattern → value` chips), full `memberOf`, `info`, and `distinguishedName`.
- **Data loading:**
  - On load, read `window.__DISCOVERY__`. If present, `table.setData(data.groups)` and populate the header.
  - If **absent/undefined**, show a friendly empty-state overlay with a drag-drop zone and a `<input type="file">`; on drop/select of a `.json` (or a `.js` beginning with `window.__DISCOVERY__ =`), parse it (strip the `window.__DISCOVERY__ = ` prefix and trailing `;` for the `.js` case, then `JSON.parse`) and render. Parse errors show an inline message (no dialogs/alerts).
  - Guard every array access defensively (`Array.isArray(x) ? x : []`) since PS 5.1 JSON may render empty collections oddly.
- **Security:** confirm no `innerHTML =` assignment anywhere receives `window.__DISCOVERY__`-derived data. Static chrome may use `innerHTML` for fixed markup, but all data flows through `textContent`/`createTextNode`/Tabulator's default (non-html) formatters.

- [ ] **Step 3: Create the fixture export helper**

Create `tests/fixtures/Export-FixtureJson.ps1` (mirrors `Export-FixtureHtml.ps1`):

```powershell
<#
.SYNOPSIS
    Runs the engine pipeline over the fixture (no live AD) and writes the interactive
    report's sidecar files via Write-JsonReport, plus copies the viewer, so the
    rendered output can be driven in a browser.

.EXAMPLE
    pwsh -NoProfile -File ./tests/fixtures/Export-FixtureJson.ps1 -OutputDirectory ./out
#>
[CmdletBinding()]
param([string]$OutputDirectory = (Join-Path ([System.IO.Path]::GetTempPath()) 'discovery-viewer'))

$ErrorActionPreference = 'Stop'
$fixtureDir = $PSScriptRoot
$testsDir   = Split-Path -Parent $fixtureDir
$root       = Split-Path -Parent $testsDir

. (Join-Path $testsDir '_TestHelpers.ps1')
. (Join-Path $fixtureDir 'Import-DiscoveryFixture.ps1')

$data = Get-FixtureDiscoveryData -FixtureDir $fixtureDir
$selected = Invoke-DiscoveryEngine -Groups $data.Groups -InputData $data.InputData `
    -VendorUsers $data.VendorUsers -DnIndex $data.DnIndex

$summary = [pscustomobject]@{
    TotalGroups   = $selected.Count
    FailedDomains = $data.FailedDomains
    Warnings      = $data.Warnings
    GeneratedAt   = (Get-Date).ToString('u')
}

if (-not (Test-Path -LiteralPath $OutputDirectory)) { New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null }
Write-JsonReport -Results $selected -Summary $summary -OutputDirectory $OutputDirectory
Copy-Item -LiteralPath (Join-Path $root 'src/Report/assets/viewer.html') `
    -Destination (Join-Path $OutputDirectory 'discovery-report.html') -Force
Write-Host ("Wrote interactive report for {0} group(s) to {1}" -f $selected.Count, $OutputDirectory)
```

- [ ] **Step 4: Generate real data and validate in a browser**

Generate the sidecar + viewer into the scratchpad:

Run: `pwsh -NoProfile -File ./tests/fixtures/Export-FixtureJson.ps1 -OutputDirectory /tmp/claude-1000/-var-home-ashton-dev-misc-powershell-ad-group-discovery/364189e4-a496-4382-8092-d0e5af4ec171/scratchpad/viewer`

Then open `discovery-report.html` in a browser (Chrome/Edge via the browser automation tools) and verify:
- The grid loads with the 13 fixture groups, grouped by Domain, groups collapsible with counts.
- Changing "Group by" to Confidence regroups; Confidence sorts by rank not alphabetically.
- A header filter (e.g. Confidence = High) filters rows; global search filters across columns.
- Clicking a row expands the detail panel with members, reasons (pattern → value), memberOf.
- Column show/hide reveals the hidden columns; Export CSV downloads the filtered view.
- The page looks clean and usable (frontend-design applied).

- [ ] **Step 5: Validate XSS hardening**

Copy the generated `discovery-data.js` to the scratchpad and edit one group's `description` to contain `<img src=x onerror="window.__pwned=1">` (and its `name` to include `<b>x</b>`). Reload the viewer and confirm: the markup shows as literal text in the cell and in the row-detail panel, no image-load/error fires, and `window.__pwned` is `undefined` (check via the console). This confirms the text-not-HTML requirement.

- [ ] **Step 6: Commit**

```bash
git add src/Report/assets/viewer.html tests/fixtures/Export-FixtureJson.ps1
git commit -m "feat: add interactive Tabulator viewer for discovery report"
```

---

### Task 3: Wire the `Json` format into the orchestrator

**Files:**
- Modify: `src/Find-VendorAdGroup.ps1` (param ValidateSet + default at lines 10; report block near lines 60-62)
- Modify: `Find-VendorAdGroup.ps1` (repo-root runner, ValidateSet at line 19)
- Test: `tests/Find-VendorAdGroup.Tests.ps1`

**Interfaces:**
- Consumes: `Write-JsonReport` (Task 1) and the `viewer.html` asset (Task 2).
- Produces: `Find-VendorAdGroup -Formats Json` writes `discovery-data.js`, `discovery-data.json`, and `discovery-report.html` into `-OutputDirectory`.

- [ ] **Step 1: Write the failing test**

Add to `tests/Find-VendorAdGroup.Tests.ps1` inside the `Describe 'Find-VendorAdGroup'` block (the `Mock Get-AdDiscoveryData` in its `BeforeAll` already supplies data):

```powershell
    It 'writes the interactive JSON sidecar and viewer when Json format selected' {
        $out = Join-Path $tmp 'json-reports'
        Find-VendorAdGroup -UsersCsv "$tmp/users.csv" -DomainsCsv "$tmp/domains.csv" `
            -KeywordsCsv "$tmp/keywords.csv" -KnownGroupsCsv "$tmp/known.csv" -ExcludeGroupsCsv "$tmp/exclude.csv" `
            -OutputDirectory $out -Formats @('Json')
        Test-Path (Join-Path $out 'discovery-data.js')   | Should -BeTrue
        Test-Path (Join-Path $out 'discovery-data.json') | Should -BeTrue
        Test-Path (Join-Path $out 'discovery-report.html') | Should -BeTrue
        (Get-Content (Join-Path $out 'discovery-data.js') -Raw) | Should -Match 'window\.__DISCOVERY__'
        $data = Get-Content (Join-Path $out 'discovery-data.json') -Raw | ConvertFrom-Json
        $data.groups[0].name | Should -Be 'Acme Admins'
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path ./tests/Find-VendorAdGroup.Tests.ps1 -Output Detailed"`
Expected: FAIL — `'Json'` is not a valid `-Formats` value (ValidateSet rejects it).

- [ ] **Step 3: Update the module function ValidateSet, default, and wiring**

In `src/Find-VendorAdGroup.ps1`, change the `-Formats` param (line 10) from:

```powershell
        [ValidateSet('Csv','Html','Console')][string[]]$Formats = @('Csv','Html','Console'),
```

to:

```powershell
        [ValidateSet('Csv','Html','Console','Json')][string[]]$Formats = @('Csv','Html','Console','Json'),
```

Then add a Json block alongside the existing `Html` block (after the `if ($Formats -contains 'Html') { ... }` block, before the `Console` block):

```powershell
    if ($Formats -contains 'Json') {
        Write-JsonReport -Results $selected -Summary $summary -OutputDirectory $OutputDirectory
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Report/assets/viewer.html') `
            -Destination (Join-Path $OutputDirectory 'discovery-report.html') -Force
    }
```

(`$PSScriptRoot` in `src/Find-VendorAdGroup.ps1` is `src/`, so the asset path is `src/Report/assets/viewer.html`.)

- [ ] **Step 4: Update the repo-root runner ValidateSet**

In the repo-root `Find-VendorAdGroup.ps1`, change line 19 from:

```powershell
    [ValidateSet('Csv','Html','Console')][string[]]$Formats,
```

to:

```powershell
    [ValidateSet('Csv','Html','Console','Json')][string[]]$Formats,
```

- [ ] **Step 5: Run test to verify it passes**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path ./tests/Find-VendorAdGroup.Tests.ps1 -Output Detailed"`
Expected: PASS (all tests, including the new one).

- [ ] **Step 6: Commit**

```bash
git add src/Find-VendorAdGroup.ps1 Find-VendorAdGroup.ps1 tests/Find-VendorAdGroup.Tests.ps1
git commit -m "feat: add Json report format to Find-VendorAdGroup"
```

---

### Task 4: End-to-end fixture assertion + docs

**Files:**
- Modify: `tests/Fixture.Tests.ps1` (the `Describe 'Fixture: public Find-VendorAdGroup ...'` block, which already runs a full `Find-VendorAdGroup`)
- Modify: `README.md`, `CLAUDE.md`

**Interfaces:**
- Consumes: the wired `Json` format (Task 3).
- Produces: an integration assertion that a fixture run emits a valid, populated sidecar payload.

- [ ] **Step 1: Write the failing test**

In `tests/Fixture.Tests.ps1`, add `'Json'` to the `-Formats` array of the `Find-VendorAdGroup` call in the second `Describe`'s `BeforeAll` (currently `-Formats @('Csv','Html')` → `-Formats @('Csv','Html','Json')`), and capture the payload right after the existing `$script:html = ...` line:

```powershell
        $script:discovery = Get-Content (Join-Path $script:outDir 'discovery-data.json') -Raw | ConvertFrom-Json
```

Then add this `It` block inside that `Describe`:

```powershell
    It 'writes an interactive JSON payload with one entry per surfaced group' {
        Test-Path (Join-Path $script:outDir 'discovery-data.js')     | Should -BeTrue
        Test-Path (Join-Path $script:outDir 'discovery-report.html') | Should -BeTrue
        @($script:discovery.groups).Count | Should -Be 13
        $atlas = $script:discovery.groups | Where-Object { $_.name -eq 'Project Atlas Team' }
        $atlas.confidence | Should -Be 'Confirmed'
        @($atlas.reasons).Count | Should -BeGreaterThan 0
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path ./tests/Fixture.Tests.ps1 -Output Detailed"`
Expected: FAIL — before adding `'Json'` to `-Formats` the files are absent; after the edit above the test file references them, so run it once with the edit in place. If you staged the `-Formats`/capture edits and the `It` together, expect PASS; to see a genuine RED, add the `It` first and run before editing `-Formats` (files missing → fail).

- [ ] **Step 3: Confirm the implementation (already done in Task 3) satisfies it**

No source change needed — Task 3 produces the files. Ensure the `-Formats @('Csv','Html','Json')` and the `$script:discovery` capture edits from Step 1 are in place.

- [ ] **Step 4: Run test to verify it passes**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path ./tests/Fixture.Tests.ps1 -Output Detailed"`
Expected: PASS.

- [ ] **Step 5: Update docs**

In `README.md`, document the new `Json` format: it emits `discovery-data.js` + `discovery-data.json` and a self-contained `discovery-report.html` interactive viewer (sort/filter/group-by/collapse, search, column show-hide, row detail, CSV export); double-click the HTML to view — no server needed.

In `CLAUDE.md`, under the report layer / conventions, note: `Write-JsonReport` emits the sidecar payload consumed by the static `src/Report/assets/viewer.html`; the viewer must render attacker-influenceable fields as text (never the `html` formatter / `innerHTML` with data), same security bar as the other report paths.

- [ ] **Step 6: Run the full suite + lint**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path ./tests -Output Detailed"`
Expected: all green, no regressions.

Run: `pwsh -NoProfile -Command "Invoke-ScriptAnalyzer -Path . -Recurse -Settings ./PSScriptAnalyzerSettings.psd1"`
Expected: no new findings.

- [ ] **Step 7: Commit**

```bash
git add tests/Fixture.Tests.ps1 README.md CLAUDE.md
git commit -m "test: assert interactive JSON report end-to-end; document Json format"
```

---

## Self-Review

**Spec coverage:**
- Tabulator, inlined, offline → Task 2 Steps 1-2. ✓
- JSON sidecar + `.js` `window.__DISCOVERY__` auto-load → Task 1 (writer) + Task 2 (script-tag load). ✓
- Default grouping = Domain → Task 2 Step 2 (`groupBy:"domain"`). ✓
- Extras: global search, column show/hide + reorder, row detail, export filtered → Task 2 Step 2. ✓
- Additive; existing reports untouched → new format is opt-in via ValidateSet; no existing writer changed. ✓
- Security (text not HTML; hostile-string check) → Global Constraints + Task 2 Steps 2 & 5. ✓
- Payload shape → Task 1 Step 3 matches spec fields. ✓
- Tests: writer unit, orchestrator wiring, fixture e2e → Tasks 1, 3, 4. ✓
- Docs → Task 4 Step 5. ✓
- Empty/error load state (file picker/drag-drop) → Task 2 Step 2. ✓

**Placeholder scan:** No TBDs; every code step shows complete code. Tabulator version is pinned with a documented fallback. ✓

**Type consistency:** `Write-JsonReport -Results -Summary -OutputDirectory` is used identically in Tasks 1, 2, 3. Output filenames (`discovery-data.js/.json`, `discovery-report.html`) are consistent across all tasks. Payload field names (`groups`, `name`, `confidence`, `reasons.pattern`, `memberCounts.known`, `memberOf`) match between writer (Task 1) and consumers (Tasks 2, 3, 4). ✓
