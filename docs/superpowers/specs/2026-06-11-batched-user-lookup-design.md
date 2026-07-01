# Batched vendor-user lookup + `-MaxIterations` removal — design

Date: 2026-06-11
Origin: triage of `docs/2026-06-10-simplify-skipped-findings.md`. Two findings were
promoted: the "worth doing later" batched `Get-ADUser` change, and the
`-MaxIterations` removal (now decided by the parameter's owner). All other skipped
findings remain skipped; their rationale in that doc is unchanged.

## A. Batch the per-user-per-domain `Get-ADUser` queries

### Problem

`Get-AdDiscoveryData` issues one LDAP round trip per CSV user per domain
(D×U sequential queries; 20 domains × 200 users = 4,000 calls). The SID dedupe
runs after the query, so already-resolved users are still re-queried in every
remaining domain. Wall-clock cost dominates multi-domain runs.

### Design

**New helper: `src/Ad/New-SamLdapFilter.ps1`** — pure, no AD calls, two functions:

- `ConvertTo-LdapFilterValue [string]` — RFC 4515 escaping. Order matters:
  `\` → `\5c` first, then `*` → `\2a`, `(` → `\28`, `)` → `\29`, NUL → `\00`.
- `New-SamLdapFilter -SamAccountNames [string[]]` — returns
  `(|(sAMAccountName=a)(sAMAccountName=b)…)`; a single name gets no `(|…)`
  wrapper; values pass through `ConvertTo-LdapFilterValue`.

**`Get-AdDiscoveryData` changes:**

1. **Validate sams once, before the domain loop** (today this runs per domain):
   skip blank sams; skip sams matching `['()*\\/]` with the existing
   "suspicious SamAccountName" warning. The guard is kept *in addition to*
   escaping (defense in depth). Behavior delta: the suspicious warning now fires
   once per user instead of once per user per domain.
   Build a case-insensitive `sam → csvUser` hashtable so query results can be
   mapped back to their CSV row (optional `UUserId` feeds `ConvertTo-IdentityTokens`).
2. **Per domain**: chunk the valid sams at a constant `$samBatchSize = 200` and
   issue one `Get-ADUser -LDAPFilter <filter> -Properties $userProps` per chunk.
   D×U calls become D×⌈U/200⌉.
3. **Failure handling** (decided: per-domain warnings only): a thrown chunk
   query adds one warning — `"User lookup failed in '<domain>': <message>"` —
   and that chunk's users are unresolved in that domain. Users absent from
   results stay silent, exactly as today. The old per-user
   `"Lookup failed for user 'X' in 'Y'"` warning is retired.
4. **Preserved semantics**: every domain is still queried for all valid sams
   (a different physical user sharing a sam in another domain is still found);
   SID dedupe stays post-query; the emitted vendor-user object shape is
   unchanged, so nothing downstream of the adapter changes.

### Constraints

- Windows PowerShell 5.1 compatible; only `Get-AdDiscoveryData` touches AD cmdlets.
- Cannot be validated against a live directory from this environment. The
  escaping unit tests below are the compensating control; the first live
  multi-domain run should sanity-check resolved-user counts and warnings.

## B. Remove `-MaxIterations` from the public API

The closure loop terminates at fixed point; the parameter is a never-used safety
backstop plumbed through three layers. Remove it from:

- `Find-VendorAdGroup.ps1` (root runner)
- `src/Find-VendorAdGroup.ps1` (module function)
- `src/Engine/Invoke-DiscoveryEngine.ps1`

`Expand-VendorGroupClosure` keeps its `$MaxIterations = 25` parameter as the
internal backstop (it is not exported; its own test exercises it). Update the
README's parameter table. Historical specs/plans are left as-is.

## Testing

- **New `tests/New-SamLdapFilter.Tests.ps1`**: each escape char individually; a
  combined hostile payload (e.g. `*)(uid=*))(|(uid=*`); backslash escaped before
  its own escape sequences; single-name vs multi-name filter shape; empty input.
- **`tests/Get-AdDiscoveryData.Tests.ps1` updates** (mocked `Get-ADUser`):
  one call per domain for ≤200 users; ⌈U/200⌉ calls when over the batch size;
  `-LDAPFilter` contains escaped values; per-domain warning on a throwing chunk;
  SID dedupe across domains unchanged; suspicious-sam skip (single warning);
  CSV `UUserId` reaches token building via the sam→csvUser map.
- **`-MaxIterations` removal**: drop/adjust any test passing it through the
  public chain; `Expand-VendorGroupClosure.Tests.ps1` keeps its direct usage.
- Fixture integration tests (`Fixture.Tests.ps1`) bypass the AD adapter and must
  pass unchanged. Full suite + `Invoke-ScriptAnalyzer` green before completion.
