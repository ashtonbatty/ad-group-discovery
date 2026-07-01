# Vendor AD Group Discovery — Design

**Date:** 2026-06-05
**Status:** Approved (brainstorming complete; ready for implementation plan)

## Purpose

Discovery Active Directory across multiple domains to discover the groups that belong
to — or are used by — a specific vendor, in a large multi-vendor environment with
inconsistent organisation, structure, and naming conventions. Produce a report of
the discovered and known groups with the detail an discoverer needs to triage them.

Primary language: **PowerShell 5.1**, using the **RSAT ActiveDirectory module**.
Standard .NET assemblies may be used where helpful.

## Inputs

Five CSV files, one per list (paths passed as parameters):

| File | Columns | Notes |
|---|---|---|
| `users.csv` | `SamAccountName`, `UUserId` (optional), `DisplayName` (optional) | `SamAccountName` is the reliable join key. `UUserId` is an additional description-match token. `DisplayName` is used for reporting only and is never a description-match token. |
| `domains.csv` | `Domain`, `Server` (optional), `Name` (optional) | Each domain is queried via `-Server`. |
| `keywords.csv` | `Keyword` | Vendor names **and** keywords, one per row. |
| `knowngroups.csv` | `Domain`, `Identity` | `Identity` = group name or DN. Always included in the report, marked **Confirmed**. |
| `excludegroups.csv` | `Domain`, `Identity` | Always removed from results; the count is reported in the summary. |

Malformed or empty required CSVs fail fast at input validation with a clear message.

## Architecture

Modular pipeline with clean layers. The matching **engine** is composed of pure
functions (PSCustomObject in → annotated result out) so it is fully unit-testable
with Pester without a live directory. The **AD adapter** is the only code that
touches `Get-AD*` cmdlets and is kept thin. Report writers consume one common
result shape and are independently swappable.

### File layout

```
ad-group-discovery/
  Find-VendorAdGroup.ps1     # thin runner: parses params, loads module, calls public fn
  VendorAdGroupDiscovery.psd1 / .psm1   # module manifest + root; exports Find-VendorAdGroup
  src/
    Input/    Read-DiscoveryInput.ps1            # read + validate the 5 CSVs
    Ad/       Get-AdDiscoveryData.ps1            # ONLY code touching Get-AD* (the adapter)
              Resolve-DirectoryIndex.ps1     # build DN/SID -> name maps across domains
    Engine/   Find-CandidateGroups.ps1       # pure matchers (one fn per pattern)
              Get-MatchConfidence.ps1        # scoring + banding
              Expand-VendorGroupClosure.ps1  # iterate nesting to closure
    Report/   Write-CsvReport.ps1
              Write-HtmlReport.ps1
              Write-ConsoleSummary.ps1
  tests/      *.Tests.ps1                    # Pester, mostly against the pure engine
  samples/    *.csv                          # example inputs
  README.md
  PSScriptAnalyzerSettings.psd1             # match workspace lint conventions
  docs/superpowers/specs/                   # this design + future specs
```

### Layers

1. **Input layer** (`Read-DiscoveryInput.ps1`) — reads and validates the five CSVs,
   returns a normalized input object.
2. **AD adapter** (`Get-AdDiscoveryData.ps1`, `Resolve-DirectoryIndex.ps1`) — the only
   code that calls `Get-AD*`. Bulk-loads groups and resolves identities.
3. **Matching engine** (`Find-CandidateGroups.ps1`, `Get-MatchConfidence.ps1`,
   `Expand-VendorGroupClosure.ps1`) — pure functions producing annotated candidates.
4. **Report writers** (`Report/*`) — consume the common result shape.

## AD access & identity resolution (adapter)

Per domain (`-Server <domain>`, optional `-Credential`):

- **Bulk-load groups once:**
  `Get-ADGroup -Filter * -Properties description, info, managedBy, member, memberOf,
  groupScope, groupCategory, mail, adminCount, whenCreated, whenChanged,
  distinguishedName`.
- **Resolve vendor users:** look up each `SamAccountName` in every discovered domain;
  pull `displayName, givenName, sn, cn, name, userPrincipalName, mail,
  distinguishedName, objectSid`. Build description identity tokens from the
  resolved `sAMAccountName`, optional CSV `UUserId`, and `mail`; display names
  remain reporting metadata.
- **Directory index:** global `DN → name` and `SID → name` maps spanning **all**
  discovered domains (users *and* groups), so members, owners, and `memberOf` resolve
  cross-domain. Foreign SIDs from non-discovered domains are shown raw with an
  `[unresolved]` note. Lookups are cached.

## Matching patterns

Each pattern that fires emits a **match reason** (pattern name + the matched value):

| Pattern | Signal strength | Matched value recorded |
|---|---|---|
| Group **name** contains keyword | Strong (3) | the keyword |
| Group **container/OU** (in DN) contains keyword | Strong (3) | the OU + keyword |
| **managedBy/owner** is a vendor user | Strong (3) | the user |
| In **known-groups** list | Confirmed | — |
| **Description/info** mentions a vendor user (`sAMAccountName`, `UUserId`, or email) | Medium (2) | user + matched token |
| **Description/info** mentions a trusted group name | Medium (2) | the group name |
| **Description/info** contains keyword | Medium (2) | the keyword |
| Group **contains a confirmed vendor group** (nested) | Medium (2) | the child group |
| Direct **member** is a vendor user | Weak (1, sums by count, capped) | the user(s) |

Both `description` and `info` (the "notes" attribute, commonly used for extra
documentation) are searched for the description-based patterns.

Trusted group-name discovery begins with known or independently matched groups and
propagates to groups found through description references. Each normalized group
name is searched at most once per domain, using a per-domain query ledger.

## Confidence scoring

Weighted sum of fired patterns: Strong = 3, Medium = 2, Weak = 1 (multiple weak
member matches sum, with a cap). Banding:

- **Confirmed** — present in the known-groups list.
- **High** — score ≥ 3.
- **Medium** — score = 2.
- **Low** — score = 1.

Every result carries its numeric **score** and the full list of **match reasons**,
so the discoverer can triage and see exactly why each group surfaced.

## Nesting closure

Implements the "a group has another vendor-related group as a member" pattern,
iterated to closure:

- **Seeds** = known groups ∪ groups scoring ≥ 2 from *direct* (non-propagated)
  signals.
- For each confirmed vendor group, its `memberOf` entries (within discovered domains)
  become candidates with the reason "contains vendor group X" (+2).
- Repeat until no new groups are added. A visited-set makes it cycle-safe, and a
  `-MaxIterations` cap (default 25) bounds it so it cannot run away.

## Result shape

One object per group:

`Domain, Name, DistinguishedName, Description, Info, Owner, Members (vendor members
flagged), MemberOf, GroupScope, GroupCategory, Mail, AdminCount, WhenCreated,
WhenChanged, Confidence, Score, MatchReasons, Source (Discovered | Known)`.

`Members` lists **direct** members only (recursive expansion would explode);
vendor users among them are flagged. `Owner` is the resolved `managedBy`.

## Reports (swappable, common shape)

All three writers consume the same result collection:

- **CSV** — flat, one row per group; lists and match reasons joined into delimited
  cells. The workhorse output for sort/filter/pivot/diff.
- **HTML** — self-contained, grouped by domain then confidence band, match reasons
  highlighted, with a run-summary header.
- **Console** — counts per domain, per confidence band, and per match-reason; lists
  failed domains and unresolved principals.

Output code is kept cleanly separated from input and processing code so writers can
be added, removed, or replaced without touching the engine.

## Public parameters (`Find-VendorAdGroup`)

```
-UsersCsv -DomainsCsv -KeywordsCsv -KnownGroupsCsv -ExcludeGroupsCsv
-OutputDirectory
-Formats @('Csv','Html','Console')      # default: all three
-Credential                              # optional; applied to all domains
-MaxIterations 25                        # closure safety cap
-SecurityGroupsOnly                      # switch; default includes distribution groups too
-MinimumConfidence Low                   # report filter; default shows all bands
```

## Error handling

- **Per-domain `try/catch`:** an unreachable domain or bad credentials logs a
  warning, records the domain as **failed** in the summary, and the run **continues**
  with the remaining domains.
- **Input validation:** malformed or empty required CSVs fail fast with a clear
  message before any AD query runs.
- **Non-fatal issues** (unresolved SIDs, missing attributes) are collected into a
  warnings list surfaced in the console summary and the HTML report.

## Testing

- **Pester** — the bulk of coverage targets the pure engine with synthetic
  group/user objects: each matcher, scoring/banding, closure (including cycles and
  the iteration cap), and exclusion handling. Input validation and report-writer
  output (expected columns/sections) are also covered. The AD adapter gets a small
  number of tests with mocked `Get-AD*` cmdlets.
- **PSScriptAnalyzer** — clean against the workspace settings.

## Performance note

The chosen approach bulk-loads all groups per domain once and analyses in memory.
This is fine for tens of thousands of groups and acceptable for more, but memory
grows with group count. If a domain proves too large, a future enhancement could
switch that domain's load to targeted server-side LDAP filters; the adapter
boundary makes this swap local.

## Out of scope (YAGNI)

- Per-domain distinct credentials (single optional `-Credential` for now).
- Recursive member expansion in the report (direct members only).
- Writing changes back to AD — this is read-only discovery tooling.
- Excel (.xlsx) output — CSV + HTML + console cover the stated needs.
