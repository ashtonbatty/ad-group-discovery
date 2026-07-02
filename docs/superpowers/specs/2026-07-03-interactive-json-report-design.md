# Interactive JSON-backed Discovery Report — Design

**Date:** 2026-07-03
**Status:** Approved (brainstorm)

## Problem

The existing HTML report (`Write-HtmlReport`) bakes all discovery results into a static
set of tables grouped by domain. It is a fine at-a-glance artifact and a good fallback for
locked-down / no-JS environments, but it offers no sorting, filtering, grouping, or
collapsing. For a reviewer triaging vendor groups across a multi-domain forest, that is
tedious.

We want an **alternative, additive** report: an interactive viewer that presents the same
data with sort / filter / group-by / group-collapse and a few usability extras, loading its
data from an external file rather than embedding it.

Nothing about the existing reports changes. This is purely additive.

## Decisions (from brainstorming)

- **Grid library: Tabulator** (pure JS, zero dependencies, MIT). Only free option that does
  all four required interactions natively — column sort, per-column header filters, group-by,
  and collapsible groups. AG Grid row-grouping is Enterprise-only; Grid.js/DataTables lack
  native group-by-with-collapse; DuckDB/sql.js-WASM is multi-MB overkill that renders nothing
  (still needs a grid on top) and needs COOP/COEP that `file://` can't provide. Tabulator's
  minified JS + CSS are **inlined** into the viewer so it works offline on an RSAT box with no
  CDN.
- **Data format: JSON** (not CSV reuse). Reasons: the CSVs are hardened by `Protect-CsvCell`
  (prepends `'`/tab to cells starting with `= + - @`), which a viewer would display as
  artifacts; and the model is nested (`MemberDetails[]`, `Reasons[]`), which CSV had to flatten
  and split into two files. JSON is both easier and higher-fidelity.
- **Load mechanism: JS sidecar, auto-loading.** A double-clicked `file://` HTML cannot
  `fetch()` a sibling file (Chrome blocks it, origin null), but a `<script src>` subresource
  load is not blocked. So the engine emits `discovery-data.js` containing
  `window.__DISCOVERY__ = {...}`, and the viewer references it with a `<script>` tag —
  zero-click, no server, cross-browser. A plain `.json` is emitted alongside for programmatic
  use and as the drag-drop secondary load path.
- **Default grouping: Domain** (matches the current report's sectioning), re-groupable at will.
- **Extras: all four** — global search box, column show/hide + reorder, expandable row detail,
  export filtered view to CSV.
- **WASM database: no.** Dataset scale (dozens to low thousands of rows) doesn't justify it.

## Architecture

Three additive pieces:

1. **`Write-JsonReport`** — new pure function in `src/Report/`. Takes `$Results` + `$Summary`,
   shapes them into a plain object, and writes two files to the output directory:
   - `discovery-data.js` — `window.__DISCOVERY__ = { ... };`
   - `discovery-data.json` — the same payload as bare JSON.
   It performs **no** `Protect-CsvCell` mangling (JSON is inherently injection-safe; escaping
   is the viewer's job at render time).

2. **`viewer.html`** — new static asset at `src/Report/assets/viewer.html`, with Tabulator +
   all UI JS/CSS inlined. Identical every run, so it is a repo asset, not a generated string.
   Copied to the output dir as `discovery-report.html`.

3. **Wiring** — add `'Json'` to the `-Formats` ValidateSet in `Find-VendorAdGroup`. When
   selected, call `Write-JsonReport` and copy `viewer.html` → `discovery-report.html`.

### Data flow

```
Invoke-DiscoveryEngine → Write-JsonReport → discovery-data.js (+ .json)
user double-clicks discovery-report.html
  → <script src="discovery-data.js"> populates window.__DISCOVERY__
  → Tabulator renders
```

## Payload shape

```jsonc
{
  "generatedAt": "2026-07-03 10:00:00",
  "summary": { "totalGroups": 12, "failedDomains": [], "warnings": [] },
  "groups": [
    {
      "domain": "corp.example.com",
      "name": "Vendor-Admins",
      "confidence": "High",
      "score": 8,
      "source": "...",
      "description": "...",
      "info": "...",
      "owner": "...",
      "memberOf": ["..."],
      "groupScope": "Global",
      "groupCategory": "Security",
      "mail": "...",
      "adminCount": 1,
      "whenCreated": "...",
      "whenChanged": "...",
      "distinguishedName": "CN=...",
      "reasons": [ { "pattern": "NameKeyword", "value": "vendor" } ],
      "memberCounts": { "known": 2, "nested": 1, "other": 5 },
      "members": [
        { "memberType": "Known", "samAccountName": "jdoe",
          "displayName": "John Doe", "distinguishedName": "CN=..." }
      ]
    }
  ]
}
```

Field names map from the engine result objects (`Domain`, `Name`, `Confidence`, `Score`,
`Source`, `Description`, `Info`, `Owner`, `MemberOfDisplay`, `GroupScope`, `GroupCategory`,
`Mail`, `AdminCount`, `WhenCreated`, `WhenChanged`, `DistinguishedName`, `Reasons` with
`Pattern`/`Value`, `MemberDetails` with `MemberType`/`SamAccountName`/`DisplayName`/
`DistinguishedName`). `memberCounts` is derived the same way `Write-CsvReport` derives its
Known/Nested/Other counts.

## Viewer UI

**Layout:** header strip (title, generated-at, total groups, failed-domains/warnings banner),
toolbar, then the Tabulator grid filling the remaining height.

**Toolbar:**
- Global search — filters across all columns.
- Group by — dropdown, default **Domain**; also Confidence, GroupScope, GroupCategory, Source,
  None. Groups collapsible with per-group count badge; collapse-all / expand-all toggle.
- Column picker — show/hide columns and drag-reorder.
- Export — downloads currently filtered/sorted rows as CSV.

**Grid columns:** Confidence (colored band swatch: Confirmed/High/Medium/Low), Score, Name,
Owner, Description, #Members (Known/Nested/Other), Member Of, Scope/Category. Hidden by
default: Info, Mail, AdminCount, WhenCreated, WhenChanged, DistinguishedName.
- Every column sortable + header filter (text/like for strings, `>=` number filter for Score,
  select dropdown for Confidence/Scope/Category).
- Confidence sorts by rank (Confirmed > High > Medium > Low), not alphabetically.

**Row detail:** clicking a row expands an inline panel with the full member list
(name · sam · type · DN), full match-reasons (Pattern → Value chips), Member-Of, Info, and DN.

**Empty/error state:** if `window.__DISCOVERY__` is undefined (data.js missing / not beside the
HTML), show a friendly message plus a drag-drop / file-picker so the user can point at a
`data.js` or `.json` — the secondary load path.

**Look & usability:** apply frontend-design guidance for a clean, non-templated look; validate
by driving the viewer in a real browser against the fixture data.

## Security (non-negotiable — new report path, per CLAUDE.md)

Group metadata is attacker-influenceable. Every such field (name, description, info, owner,
member names, reasons, DNs) MUST render as **text, not HTML**:
- Rely on Tabulator's default cell escaping; do **not** apply the `html` formatter to
  data-bearing columns.
- The row-detail panel builds DOM nodes via `textContent` / element creation, never
  `innerHTML` with data.
- The JSON writer emits data as-is; escaping is a render-time concern.

A test fixture/asset group whose description contains `<img src=x onerror=...>` is used to
confirm inert rendering in the browser.

## Testing

- `tests/Write-JsonReport.Tests.ps1` — `.js` and `.json` files are written; the
  `window.__DISCOVERY__ =` wrapper is present; the payload round-trips via `ConvertFrom-Json`;
  nested members/reasons survive; no `Protect-CsvCell` artifacts (`'`, tab prefixes) appear.
- `tests/Find-VendorAdGroup.Tests.ps1` — `-Formats Json` triggers the writer and copies the
  viewer asset; `'Json'` is a valid ValidateSet value.
- `tests/Fixture.Tests.ps1` — end-to-end assertion that a fixture run produces a valid payload.
- Browser validation of `viewer.html` (driven): load fixture data; exercise sort, filter,
  group-by, collapse, row detail, export; confirm the hostile-string group renders inert. The
  static HTML is not Pester-unit-tested.

## Docs

Short note in `README.md` and `CLAUDE.md` about the new `Json` format and the interactive
report.

## Out of scope

- Changing or removing the existing CSV / HTML / console reports.
- SQL / WASM-database querying (possible clean follow-up).
- Server-based hosting of the report.
