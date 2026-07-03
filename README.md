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
| users.csv | `SamAccountName`, `UUserId` (optional), `DisplayName` (optional) |
| domains.csv | `Domain`, `Server` (optional), `Name` (optional), `CredentialUser` (optional) |
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

Options: `-Formats Csv,Html,Console,Json`, `-Credential`, `-DomainCredentials`,
`-SecurityGroupsOnly`, `-MinimumConfidence Low|Medium|High|Confirmed`.

## Per-domain credentials

Use `-Credential` when the same alternate credential can query every domain. For
one untrusted domain, add `CredentialUser` only to that row in `domains.csv`; the
script prompts once for that account and uses it for queries to that domain.

```csv
Domain,Server,Name,CredentialUser
corp.example.com,dc1.corp.example.com,Corp,
isolated.example.com,dc1.isolated.example.com,Isolated,ISOLATED\svc-ad-read
```

For non-interactive module use, pass a domain-keyed credential map instead:

```powershell
$domainCredentials = @{
    'isolated.example.com' = Get-Credential -UserName 'ISOLATED\svc-ad-read'
}

Find-VendorAdGroup `
    -UsersCsv samples/users.csv -DomainsCsv samples/domains.csv `
    -KeywordsCsv samples/keywords.csv -KnownGroupsCsv samples/known.csv `
    -ExcludeGroupsCsv samples/exclude.csv -OutputDirectory ./out `
    -DomainCredentials $domainCredentials
```

## How groups are found

Each group is matched against these patterns; each match contributes to a confidence
score (High / Medium / Low, or Confirmed for known groups):

- Vendor keyword in the group **name** or its **container/OU** (strong)
- **managedBy/owner** is a vendor user (strong)
- Vendor keyword, a listed user's **sAMAccountName/UUserId/email**, or a trusted group name
  in the **description/info** (medium)
- Group **contains another vendor group** — propagated to closure (medium)
- A vendor user is a direct **member** (weak; multiple members add up)

Description owner matching deliberately excludes display names. User tokens come
from the `SamAccountName` and optional `UUserId` in users.csv, plus the resolved
AD user's `mail` attribute. Trusted group names start with known or independently
matched groups and propagate to newly discovered description owners. A
case-insensitive per-domain ledger ensures each trusted group name is queried only
once in that domain.

Members flagged with a leading `*` in HTML/console reports are vendor users.

## Output

- `vendor-group-discovery.csv` — one row per group, keyed by `Domain\Name`, with
  `Domain` and `Name` repeated as separate columns, member-count summary columns,
  and a `MatchReasons` column
- `vendor-group-discovery-members.csv` — one row per direct group member, keyed by
  the same `Domain\Name`, with member type, `SamAccountName`, display name, and DN
- `vendor-group-discovery.html` — grouped by domain and confidence, reasons highlighted
- Console summary — counts per domain / band / reason, plus failed domains
- `Json` format (opt-in via `-Formats`) — `discovery-data.js` + `discovery-data.json`
  (the same payload, as a script tag and as plain JSON) plus a self-contained
  `discovery-report.html` interactive viewer: sort, filter, group-by, collapse,
  full-text search, column show/hide, row detail, and CSV export. Double-click
  `discovery-report.html` to open it — no server needed.

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
