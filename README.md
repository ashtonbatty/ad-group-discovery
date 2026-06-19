# Vendor AD Group Discovery

Scans Active Directory across multiple domains to discover the groups belonging to
or used by a vendor, and produces CSV, HTML, and console reports with
confidence-scored match reasons.

## Requirements

- Windows PowerShell 5.1
- RSAT ActiveDirectory module (`Import-Module ActiveDirectory`)
- Read access to each domain being discovered

## Inputs (one CSV per list)

| File | Columns |
|------|---------|
| users.csv | `SamAccountName`, `DisplayName` (optional) |
| domains.csv | `Domain`, `Server` (optional), `Name` (optional) |
| keywords.csv | `Keyword` |
| known.csv | `Domain`, `Identity` |
| exclude.csv | `Domain`, `Identity` |

`Identity` in known.csv / exclude.csv may be a group name or a distinguished name.

## Usage

```powershell
./Find-VendorAdGroup.ps1 `
    -UsersCsv samples/users.csv -DomainsCsv samples/domains.csv `
    -KeywordsCsv samples/keywords.csv -KnownGroupsCsv samples/known.csv `
    -ExcludeGroupsCsv samples/exclude.csv -OutputDirectory ./out
```

Options: `-Formats Csv,Html,Console`, `-Credential`,
`-SecurityGroupsOnly`, `-MinimumConfidence Low|Medium|High|Confirmed`.

## How groups are found

Each group is matched against these patterns; each match contributes to a confidence
score (High / Medium / Low, or Confirmed for known groups):

- Vendor keyword in the group **name** or its **container/OU** (strong)
- **managedBy/owner** is a vendor user (strong)
- Vendor keyword or a vendor user's name/ID in the **description/info** (medium)
- Group **contains another vendor group** — propagated to closure (medium)
- A vendor user is a direct **member** (weak; multiple members add up)

Members flagged with a leading `*` in HTML/console reports are vendor users.

## Output

- `vendor-group-discovery.csv` — one row per group, keyed by `Domain\Name`, with
  `Domain` and `Name` repeated as separate columns, member-count summary columns,
  and a `MatchReasons` column
- `vendor-group-discovery-members.csv` — one row per direct group member, keyed by
  the same `Domain\Name`, with member type, `SamAccountName`, display name, and DN
- `vendor-group-discovery.html` — grouped by domain and confidence, reasons highlighted
- Console summary — counts per domain / band / reason, plus failed domains

Report cells are hardened against CSV formula injection and HTML is escaped against
XSS, since group metadata can contain attacker-influenceable values.

## Development

Run the test suite (Pester 5):

```bash
pwsh -NoProfile -Command "Invoke-Pester -Path ./tests -Output Detailed"
```

Lint:

```bash
pwsh -NoProfile -Command "Invoke-ScriptAnalyzer -Path . -Recurse -Settings ./PSScriptAnalyzerSettings.psd1"
```
