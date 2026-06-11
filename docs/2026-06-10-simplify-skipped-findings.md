# Skipped /simplify findings — 2026-06-10

Findings from the 2026-06-10 `/simplify` review (four parallel agents: reuse,
simplification, efficiency, altitude) that were deliberately **not** applied, with
the reasoning. The applied findings are described in the commit
"refactor: deduplicate pipeline orchestration and shared policies".

## Worth doing later

### Batch the per-user-per-domain `Get-ADUser` queries
- **File:** `src/Ad/Get-AdDiscoveryData.ps1` (user-resolution loop)
- **Finding:** the loop issues one LDAP round trip per CSV user per domain
  (D×U sequential queries; e.g. 20 domains × 200 users = 4,000 calls). The SID
  dedupe runs after the query, so already-resolved users are still re-queried in
  every remaining domain. One OR'd `-LDAPFilter` per domain would reduce this to
  D queries and would dominate wall-clock improvement in any multi-domain run.
- **Why skipped:** changes the AD interaction semantics — per-user try/catch
  warnings ("Lookup failed for user 'X' in 'Y'") would lose granularity, and the
  suspicious-SamAccountName injection guard is written for `-Filter`, not a
  hand-built LDAP filter string (escaping rules differ). Couldn't be validated
  against a live directory from this environment. Do this as a deliberate change
  with its own tests for the batched-filter escaping and warning behavior.
- **Status:** Done 2026-06-11 — see
  `docs/superpowers/specs/2026-06-11-batched-user-lookup-design.md` and
  `src/Ad/New-SamLdapFilter.ps1`. Not yet validated against a live directory;
  sanity-check resolved-user counts and warnings on the first multi-domain run.

## Conscious trade-offs (revisit only if the pressure changes)

### Incremental `$confirmed` set / HashSet edge-dedupe in `Expand-VendorGroupClosure`
- **Finding (efficiency):** the `$confirmed` hashtable is rebuilt from scratch every
  fix-point round, and the "already added" check scans `$r.Reasons` with
  `Where-Object` per confirmed-member edge per round.
- **Why skipped:** the simplification agent independently judged the per-round
  rebuild *necessary-grade simple*; rounds are few in practice (fixture: 2–3),
  promotions are rare, and an incremental set changes when promotions become
  visible (same fixed point, but reason *order* within a group can differ, which
  is observable in CSV `MatchReasons`). Simplicity won over a modest win.

### Structured member objects instead of the `*` vendor-marker prefix
- **File:** `src/Engine/Resolve-ResultDisplay.ps1` (altitude finding)
- **Finding:** encoding "vendor member" as a `*` string prefix is a rendering
  choice made in the engine; writers can't render it natively (HTML could
  highlight; CSV is ambiguous for names genuinely starting with `*`). Emitting
  `@{ Name; IsVendor }` and letting each writer choose would be the right
  altitude.
- **Why skipped:** changes the engine output contract, all three writers, the
  fixture oracle (`tests/fixtures/README.md` documents the `*` convention), and
  several tests — disproportionate churn for a presentational gain. If a writer
  ever needs native vendor styling, do this first.

### `ConvertTo-DnKey` helper for DN case-normalization
- **Finding (altitude):** six call sites each do their own `.ToLower()` on DNs
  (`Resolve-DirectoryIndex`, `New-VendorPrincipalIndex`, `Resolve-DisplayName`,
  `Resolve-VendorPrincipal`, `Expand-VendorGroupClosure`); no single layer owns
  DN canonicalization, so a future lookup that forgets to lowercase fails
  silently.
- **Why skipped:** the helper would sit on the per-member hot path, and
  PowerShell function-call overhead is significant in tight loops. The
  convention is small and consistent today. Alternative if drift becomes real:
  normalize DNs once at the adapter boundary in `Get-AdDiscoveryData`.

### Remove `-MaxIterations` from the public API
- **Finding (simplification):** the closure loop already terminates at fixed
  point; `MaxIterations` is only a safety backstop, yet it is a public parameter
  plumbed through runner → orchestrator → engine, and nobody passes a non-default
  value.
- **Why skipped:** removing a public, documented parameter is an API/behavior
  decision, not a cleanup. The inert runner defaults *were* removed; the
  parameter itself stays until its owner decides otherwise.
- **Status:** Done 2026-06-11 — removed from the public chain; the internal
  backstop remains on `Expand-VendorGroupClosure`.

### Merge the runner's duplicated param block
- **File:** `Find-VendorAdGroup.ps1` (root runner) vs `src/Find-VendorAdGroup.ps1`
- **Finding:** the runner repeats the module function's parameter list, so every
  parameter change must be made twice.
- **Why skipped:** the duplication buys script-level tab completion and
  validation, which is the runner's whole purpose. Defaults were de-duplicated
  (module function is the single owner); the parameter *names* remain a known,
  commented duplicate.

### Shared factory for the report-test result-row literals
- **Files:** `tests/Write-CsvReport.Tests.ps1`, `tests/Write-HtmlReport.Tests.ps1`,
  `tests/Protect-CsvCell.Tests.ps1`
- **Finding (reuse):** a ~16-property shaped-result literal is restated in three
  report tests.
- **Why skipped:** each literal differs in load-bearing ways (XSS payload in the
  name, formula-injection payload in the description, member markers); a shared
  factory with overrides would hide exactly the properties each test depends on.

## False positive (do not re-apply)

### Collapse the empty-case guard in `Find-CandidateGroups`
- **Finding (simplification):** `if ($results.Count) { return ,$results.ToArray() }
  return @()` looks reducible to `,$results.ToArray()`.
- **Reality:** with an empty list, `,@()` emits a single empty-array *item*
  (Count 1) downstream instead of nothing — a test caught it
  ("omits excluded groups entirely"). The guard is load-bearing and now carries
  a comment saying so.
