# Design: Vendor user membership & account-audit reports

**Date:** 2026-07-01
**Status:** Approved (design), pending implementation plan

## Summary

Add two new CSV reports to the vendor AD group discovery tool, both scoped to the
**vendor users** (the accounts listed in `users.csv`):

1. **User→group membership report** — a normalized list of every group each vendor user
   belongs to: `UserDomain, UserSamAccountName, UserDisplayName, GroupDomain, GroupName`.
2. **User account-audit report** — one row per vendor user with account-hygiene fields:
   `UserDomain, UserSamAccountName, UserDisplayName, Enabled, LockedOut, Description,
   AccountExpirationDate, LastLogonDate, PasswordLastSet, PasswordExpiry,
   PasswordNeverExpires, BadLogonCount`.

Both are emitted whenever `Csv` is in `-Formats` (no new parameters). CSV only.

## Decisions (from brainstorming)

- **User scope:** vendor users only (accounts from `users.csv`), not all discovered-group members.
- **Membership group scope:** *combined* — union of (a) each user's `memberOf` (all
  home-domain groups) and (b) discovered groups the user is a member of (cross-domain
  coverage for vendor groups). Rationale below.
- **Nesting:** direct memberships only (no transitive LDAP_MATCHING_RULE_IN_CHAIN expansion).
- **Format:** CSV only, hardened with `Protect-CsvCell`.
- **Trigger:** always emitted when `Csv` format is selected; no new switch.
- **`GroupName`:** the group's leaf **CN** (the `name` attribute), which can differ from a
  group's `sAMAccountName`.

## Why "combined" for the membership report

AD's `memberOf` attribute reliably lists only a user's **home-domain** group memberships.
Cross-domain memberships are represented at the group's domain as a Foreign Security
Principal (FSP) and do **not** appear in the user's `memberOf`. This codebase already works
around this — see the FSP `member` search in `Get-AdDiscoveryData` (`New-ExactFilter -Attribute 'member'`
against `CN=<sid>,CN=ForeignSecurityPrincipals,<domainDn>`).

A `memberOf`-only report would therefore make `GroupDomain` nearly always equal `UserDomain`
and silently omit the cross-domain vendor-group memberships the tool exists to find.

The combined source gives the fullest picture available from already-acquired data:
- `memberOf` → **all** home-domain groups (including non-discovered ones).
- Discovered groups' member lists → cross-domain coverage, limited to discovered/vendor groups.

## Architecture

The AD boundary stays thin: only `Get-AdDiscoveryData` gains new queried attributes.
Everything else is pure functions over the discovery data object, unit-testable without a
directory.

### 1. Data acquisition — `src/Ad/Get-AdDiscoveryData.ps1` (only AD change)

- Extend `$userProps` with: `Enabled`, `LockedOut`, `Description`, `AccountExpirationDate`,
  `LastLogonDate`, `PasswordLastSet`, `BadLogonCount`, `PasswordNeverExpires`, and the raw
  `msDS-UserPasswordExpiryTimeComputed`.
- At the vendor-user creation site (inside the per-domain loop, `~line 284`, before SID
  dedup), add to the emitted `pscustomobject`:
  - `Domain = $d.Domain` — the domain currently being queried.
  - The new audit fields (carried through verbatim; `msDS-UserPasswordExpiryTimeComputed` kept
    as the raw FileTime for downstream conversion).
- **Home-domain guarantee:** the existing SID dedup keeps the *first-resolved* instance of a
  user. Because each domain is queried against its own DC (not a GC) with a sAM filter, the
  first-resolved domain is the account's home domain. This is asserted by a test.
- Calculated Get-ADUser properties (`Enabled`, `LockedOut`, `AccountExpirationDate`,
  `LastLogonDate`, `PasswordLastSet`, `BadLogonCount`, `PasswordNeverExpires`) already null
  out the "never/none" sentinels — no manual conversion needed for these.

### 2. Pure projection functions — `src/Engine/` (new)

These are **not** part of the matching pipeline and are **not** folded into
`Invoke-DiscoveryEngine`. They are standalone pure functions called from `Find-VendorAdGroup`.

#### `Get-VendorUserMemberships`
- **Input:** `-VendorUsers` (the discovery data users) and `-Groups` (discovered groups).
- **Logic (combined source):**
  - (a) For each vendor user, for each DN in `MemberOf`: derive `GroupDomain` from the DN's
    `DC=` components (joined with `.`) and `GroupName` from the leaf CN (RDN value,
    un-escaped for `\,` etc.).
  - (b) For each discovered group, determine whether the vendor user is a member using the
    existing vendor-principal index (`New-VendorPrincipalIndex` / `Resolve-VendorPrincipal`):
    match a group `Member` DN against the user's `DistinguishedName` **and** against the
    FSP DN `CN=<sid>,CN=ForeignSecurityPrincipals,<groupDomainDn>`. Use the group's
    authoritative `Domain` and `Name`.
  - Dedup rows by `(user key, group DN lowercased)`. When a group is seen from both sources,
    prefer the discovered group's authoritative `Domain`/`Name` over the DN-derived values.
- **Output:** objects with `UserDomain, UserSamAccountName, UserDisplayName, GroupDomain, GroupName`.
- May reuse/extend a small DN-parsing helper (mirrors `Get-OuComponentsFromDn`'s
  unescaped-comma split) to extract domain + leaf CN.

#### `Get-VendorUserAccounts`
- **Input:** `-VendorUsers`.
- **Logic:** one row per user projecting the audit fields. Convert
  `msDS-UserPasswordExpiryTimeComputed` (raw Int64 FileTime) to `PasswordExpiry`:
  - `0` → blank (password expired / must change at next logon).
  - `9223372036854775807` → blank (never expires; note `[datetime]::FromFileTime` **throws**
    on this value, so it must be guarded before conversion).
  - otherwise → `[datetime]::FromFileTime(value)` formatted like other dates.
- **Output:** objects with `UserDomain, UserSamAccountName, UserDisplayName, Enabled,
  LockedOut, Description, AccountExpirationDate, LastLogonDate, PasswordLastSet,
  PasswordExpiry, PasswordNeverExpires, BadLogonCount`.

### 3. CSV report writers — `src/Report/` (new)

Both mirror `Write-CsvReport`: every cell through `Protect-CsvCell`, then
`Export-Csv -LiteralPath <path> -NoTypeInformation -Encoding UTF8`.

- `Write-UserMembershipReport` → `vendor-user-memberships.csv`
- `Write-UserAccountReport` → `vendor-user-accounts.csv`

### 4. Wiring — `src/Find-VendorAdGroup.ps1`

Inside the existing `if ($Formats -contains 'Csv')` block, after `Write-CsvReport`:
- `$memberships = Get-VendorUserMemberships -VendorUsers $data.VendorUsers -Groups $groups`
- `$accounts = Get-VendorUserAccounts -VendorUsers $data.VendorUsers`
- `Write-UserMembershipReport -Rows $memberships -Path (Join-Path $OutputDirectory 'vendor-user-memberships.csv')`
- `Write-UserAccountReport -Rows $accounts -Path (Join-Path $OutputDirectory 'vendor-user-accounts.csv')`

No new parameters on `Find-VendorAdGroup`.

## Example output

`vendor-user-accounts.csv`:

```
"UserDomain","UserSamAccountName","UserDisplayName","Enabled","LockedOut","Description","AccountExpirationDate","LastLogonDate","PasswordLastSet","PasswordExpiry","PasswordNeverExpires","BadLogonCount"
"corp.example.com","svc-acme","ACME Integration Service","True","False","ACME vendor service account","","2026-06-30 02:14:07","2025-11-02 09:41:22","2026-08-01 09:41:22","False","0"
"corp.example.com","jdoe-acme","John Doe (ACME)","True","True","ACME contractor - onsite","2026-12-31 00:00:00","2026-06-29 17:55:10","2026-05-18 08:03:44","2026-08-16 08:03:44","False","5"
"eu.example.com","asmith-acme","Anna Smith (ACME)","False","False","ACME contractor - disabled 2026-04","","2026-03-30 11:20:01","2025-09-12 14:22:09","","True","0"
```

`vendor-user-memberships.csv`:

```
"UserDomain","UserSamAccountName","UserDisplayName","GroupDomain","GroupName"
"corp.example.com","svc-acme","ACME Integration Service","corp.example.com","ACME-App-Admins"
"corp.example.com","svc-acme","ACME Integration Service","corp.example.com","Domain Users"
"corp.example.com","svc-acme","ACME Integration Service","eu.example.com","ACME-EU-Connectors"
"corp.example.com","jdoe-acme","John Doe (ACME)","corp.example.com","ACME-App-Admins"
"eu.example.com","asmith-acme","Anna Smith (ACME)","eu.example.com","ACME-EU-Connectors"
```

(`eu.example.com\ACME-EU-Connectors` for `svc-acme` is a cross-domain row present only
because of the discovered-group member side — a memberOf-only report would miss it.)

## Testing (in scope per CLAUDE.md)

- Unit `*.Tests.ps1` for each new function, named after the function:
  - `Get-VendorUserMemberships.Tests.ps1` — combined-source union, dedup by group DN,
    authoritative-name preference, DN→domain/CN parsing (incl. escaped commas), FSP-SID matching.
  - `Get-VendorUserAccounts.Tests.ps1` — field projection and the three
    `msDS-UserPasswordExpiryTimeComputed` cases (`0`, `Int64.MaxValue`, a real value).
  - `Write-UserMembershipReport.Tests.ps1` / `Write-UserAccountReport.Tests.ps1` — CSV shape,
    header, `Protect-CsvCell` hardening.
  - `Get-AdDiscoveryData` test asserting the vendor-user object carries `Domain` (home domain)
    and the new audit fields, and that SID dedup keeps the first-resolved (home) domain.
- Fixture extension:
  - Add the audit attributes to the user records in `tests/fixtures/directory.json` and the
    generator `New-DiscoveryFixture.ps1`; regenerate the fixture.
  - Add fixture-oracle assertions in the integration tests (`Fixture.Tests.ps1`) for both new
    CSVs, including at least one cross-domain membership row.
  - Update `tests/fixtures/README.md` expected-output oracle to cover the new reports.

## Caveats (documented, not blocking)

- `GroupName` is the leaf CN (`name`), which can differ from a group's `sAMAccountName`.
- `LastLogonDate` is replicated-approximate (not real-time); `BadLogonCount` is per-DC.
  Standard pragmatic choices for a discovery/audit tool.
- The membership report's cross-domain completeness is bounded by what discovery finds:
  cross-domain rows appear only for groups discovery surfaced.

## Out of scope (YAGNI)

- HTML/console rendering of the new reports.
- Transitive/nested membership expansion.
- Reporting on non-vendor accounts (all discovered-group members).
- A GC-based re-query to guarantee home-domain resolution beyond the first-resolved heuristic.
