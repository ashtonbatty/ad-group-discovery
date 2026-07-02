# Reducing work on repeated (e.g. weekly) runs — 2026-07-02

Advisory suggestions requested after the object-caching pass (commit `a47e6c3`,
"perf: cache every fetched directory object; never re-query in a run"). That
work eliminated redundant queries *within* a single run; everything below is
about cutting work *across* runs, since the tool today is fully stateless
between invocations. None of this is implemented — evaluate before building.

## Suggestions, roughly in order of value for effort

### 1. Feed each run's Confirmed/High groups back into `known.csv`
Known groups seed name-trust in round one (`Test-TrustedNameSource` — see
`src/Engine/Test-TrustedNameSource.ps1`), so transitive `DescriptionGroup`
chains converge in fewer rounds of `Expand-VendorGroupClosure`/the
related-lookup loop in `Get-AdDiscoveryData.ps1` — fewer LDAP round trips, and
the report gets more stable week over week. The input mechanism already
exists (`Read-DiscoveryInput` reads `known.csv`); this is mostly an export
step after `Write-CsvReport` runs.

### 2. Persist the member-object cache to a JSON sidecar
DN → sam/display/objectClass is nearly static, and non-vendor member
resolution (the `Get-ADObject` calls in `Resolve-AdMemberObject`) is the
largest remaining per-run query class after the caching pass. Load a sidecar
into `$memberObjectCache` at startup, query only cache misses, and re-resolve
entries older than some TTL (e.g. 30 days) so renames/deletions eventually
surface. `Add-CachedMemberObject` already normalizes every cache entry to one
shape (`DistinguishedName`, `SamAccountName`, `DisplayName`, `Name`,
`ObjectClass`), so a disk-backed cache round-trips through the same shape with
no new adapter.

### 3. Incremental discovery via `whenChanged`
Store the last successful run time per domain and AND
`(whenChanged>=<timestamp>)` into the candidate search filters, merging
results with the previous run's cached candidates instead of re-scanning the
whole domain. Membership edits bump a group's `whenChanged`, so
member-driven signals stay fresh. Two caveats:
- **Deletions are invisible** — tombstoned objects don't match a `whenChanged`
  filter, so a stale/removed group would linger in the merged result set
  until a periodic full (non-incremental) run. Schedule one monthly.
- **`whenChanged` is a full-replication attribute, not `uSNChanged`.** If
  replication-exact "changed since last run against this exact DC" semantics
  matter, use `uSNChanged` instead, but that requires pinning each domain's
  `Server` column to a fixed DC (`uSNChanged` values aren't comparable across
  DCs).

### 4. Cheap operational wins (no design needed)
- Run with `-SecurityGroupsOnly` when distribution groups aren't in scope —
  the filter is pushed into LDAP, shrinking every search server-side.
- Keep `users.csv` pruned of departed vendor accounts — every listed user
  adds a member-clause and description-token clause to *every* domain's
  searches, so stale rows cost real query volume, not just noise in the
  report.

## Deliberately not caching across runs

Account-audit fields (enabled/locked-out/bad-logon-count/password-expiry from
`Write-UserAccountReport`) should stay live every run. Freshness is the point
of a recurring audit, and they already ride free on the once-per-domain
batched `Get-ADUser` calls — there's no query cost to save by caching them,
only staleness risk to add.
