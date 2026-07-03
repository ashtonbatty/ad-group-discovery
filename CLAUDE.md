# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A Windows PowerShell 5.1 module that scans Active Directory across multiple domains to
discover the groups belonging to or used by a vendor, scoring each match by confidence and
emitting CSV / HTML / console reports. Runtime targets RSAT's `ActiveDirectory` module on
Windows; the test/dev environment here is `pwsh` on Linux (AD cmdlets are stubbed — see Testing).

## Commands

```bash
# Run the full test suite (Pester 5)
pwsh -NoProfile -Command "Invoke-Pester -Path ./tests -Output Detailed"

# Run a single test file
pwsh -NoProfile -Command "Invoke-Pester -Path ./tests/Find-CandidateGroups.Tests.ps1 -Output Detailed"

# Lint
pwsh -NoProfile -Command "Invoke-ScriptAnalyzer -Path . -Recurse -Settings ./PSScriptAnalyzerSettings.psd1"

# End-to-end smoke test over the in-repo fixture (no live AD needed)
pwsh -NoProfile -File ./tests/fixtures/Show-FixtureDiscovery.ps1
```

## Architecture

`Find-VendorAdGroup` (in `src/Find-VendorAdGroup.ps1`) is the single exported public function and
the orchestrator. Everything else is an internal helper dot-sourced from `src/`. The module
(`VendorAdGroupDiscovery.psm1`) loads by recursively dot-sourcing every `*.ps1` under `src/` and
exporting only `Find-VendorAdGroup`. `Find-VendorAdGroup.ps1` at the repo root is a thin runner
that imports the module and forwards bound parameters.

Source is layered by responsibility under `src/`:

- **`Input/`** — `Read-DiscoveryInput` parses the five input CSVs into one object.
- **`Ad/`** — `Get-AdDiscoveryData` is the *only* code that touches the live directory; it
  queries each domain, builds vendor-user identity tokens (`ConvertTo-IdentityTokens`) and a
  DN/SID index (`Resolve-DirectoryIndex`), and returns a plain data object. Member display objects
  are resolved after a global engine pre-pass (`Find-CandidateGroups` + `Expand-VendorGroupClosure`
  over all domains), in batched `distinguishedName` OR-filter searches, and only for groups the
  engine keeps (confidence above None or known). Everything downstream is pure and AD-free.
- **`Engine/`** — the matching pipeline (pure functions). Candidates are found, scored, and
  expanded here.
- **`Report/`** — `Write-CsvReport`, `Write-HtmlReport`, `Write-ConsoleSummary`, `Write-JsonReport`
  (emits the `discovery-data.js`/`.json` sidecar payload consumed by the static
  `src/Report/assets/viewer.html`, an interactive report copied to `discovery-report.html`).

The orchestration pipeline in `Find-VendorAdGroup`:

```
Read-DiscoveryInput → Get-AdDiscoveryData → Invoke-DiscoveryEngine → Write-* reports
```

`Invoke-DiscoveryEngine` (in `src/Engine/`) owns the matching pipeline and is also the
entry point used by the fixture scripts and integration tests:

```
Find-CandidateGroups → Expand-VendorGroupClosure → Select-DiscoveryResults (confidence filter)
  → Resolve-ResultDisplay (DN/SID → names) → Sort-DiscoveryResult (confidence rank)
```

Engine functions return result arrays as a single item (leading-comma idiom); call
them with plain assignment — an extra `@( )` wrap nests the array.

It returns `{ Results; Summary }`; reports are a side effect gated by `-Formats`.

### Matching model

Each group accumulates match *reasons*, which roll up to a confidence band (Low / Medium / High,
plus **Confirmed** for groups in `known.csv`). Signals: vendor keyword in group name or
container/OU (strong), `managedBy`/owner is a vendor user (strong), keyword, listed-user sam/email,
or trusted-group mention in description/info (medium), group contains another vendor group (medium, propagated by
`Expand-VendorGroupClosure`), vendor user is a direct member (weak, additive). `MemberVendorUser`
and `NestedVendorGroup` do not by themselves seed description-name trust (see
`Test-TrustedNameSource`) -- only a non-member-only signal, or membership where every member is a
vendor user, makes a group's name trusted for downstream description searches. `exclude.csv`
suppresses groups; `-SecurityGroupsOnly` drops distribution groups; `-MinimumConfidence` filters
the band. The fixture README (`tests/fixtures/README.md`) documents an exact expected-output
oracle for every signal — treat it as the behavioral spec when changing the engine.

## Testing

There is no live AD here. Two mechanisms make the engine testable on Linux `pwsh`:

1. `tests/_TestHelpers.ps1` dot-sources all of `src/` and defines no-op `Get-ADGroup`/`Get-ADUser`
   stubs *only if absent*, so Pester `Mock` can intercept them. Unit tests mock AD cmdlets to
   feed `Get-AdDiscoveryData` synthetic objects.
2. `tests/fixtures/` is a self-consistent simulated 4-domain forest (`directory.json` + input
   CSVs). `Import-DiscoveryFixture.ps1` turns it into a `Get-AdDiscoveryData`-shaped object so the
   whole pipeline runs end-to-end with no AD and no mocking. Regenerate with
   `New-DiscoveryFixture.ps1` after editing its data tables. Integration tests (`Fixture.Tests.ps1`)
   assert engine output against the fixture oracle.

Tests live in `tests/`, one `*.Tests.ps1` per source function, named after the function.

## Conventions

- **Keep the AD boundary thin.** Only `Get-AdDiscoveryData` calls AD cmdlets. New matching/report
  logic must be a pure function operating on the discovery data object so it stays unit-testable
  without a directory.
- **Report output is security-sensitive.** Group metadata is attacker-influenceable, so CSV cells
  are hardened against formula injection (`Protect-CsvCell`) and HTML is escaped against XSS. Any
  new report path must preserve this. `src/Report/assets/viewer.html` renders the JSON sidecar
  client-side and must treat every group/member field as text (DOM text nodes or an escaping
  helper) — never a `html`-style formatter or `innerHTML` with unescaped data.
- New engine/report functions get a matching `*.Tests.ps1` and, where they affect end-to-end
  behavior, an assertion in the fixture integration tests.
- Target Windows PowerShell 5.1 — avoid syntax/cmdlets unavailable in 5.1.
