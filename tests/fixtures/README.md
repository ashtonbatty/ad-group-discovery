# Discovery test fixture

A self-consistent, multi-domain Active Directory scenario for exercising the
Vendor AD Group Discovery engine without a live directory.

## Files

| File | What it is |
|------|------------|
| `New-DiscoveryFixture.ps1` | Deterministic generator. Re-run to regenerate everything below. |
| `directory.json` | The simulated directory: 4 domains, 40 users, 20 groups (full AD attributes, with consistent DN cross-references). This is what `Get-AdDiscoveryData` would return from a real forest. |
| `discovery-input/*.csv` | The five discovery-input lists for discovering the **primary vendor (Northwind Traders)**: `users.csv`, `domains.csv`, `keywords.csv`, `known.csv`, `exclude.csv`. |
| `Import-DiscoveryFixture.ps1` | Loader bridge: turns the JSON + CSVs into a `Get-AdDiscoveryData`-shaped object (`Groups`, `VendorUsers` with `Tokens`, `DnIndex`, …) so the rest of the pipeline runs with no AD and no mocking. |
| `Show-FixtureDiscovery.ps1` | Runnable demo / smoke test that runs the engine over the fixture and prints the surfaced groups. |

Not wired into the Pester suite yet — these are data + helpers you can point tests at.

## The scenario

**Forest:** `globex` (the customer). Four domains with deliberately inconsistent
naming/TLDs and two different group-organisation conventions:

| Domain | Structure | Group convention |
|--------|-----------|------------------|
| `corp.globex.com` | **A** | Vendor groups foldered into `OU=<Vendor>,OU=Vendors`; customer groups in `OU=Groups`. |
| `emea.globex.com` | **A** | Same as corp. |
| `apac.globex.local` | **B** | Every group in a single flat `OU=Groups`. |
| `dmz.globex.net` | **B** | Every group in a single flat `OU=Groups`. |

**Organisations (4):** three vendors — **Northwind Traders** (the discovered vendor),
**Contoso**, **Fabrikam** — plus the customer org **Globex** (non-vendor).

**Users (40):** 20 Northwind, 7 Contoso, 7 Fabrikam, 6 Globex — spread across all
four domains. Vendor contractors live in `OU=Contractors,OU=Vendors` (structure A)
or `CN=Users` (structure B); Globex staff in `OU=Staff` / `CN=Users`.

**Groups (20):** 10 Northwind-related, 10 other (Contoso ×3, Fabrikam ×3, Globex ×4).

So **half the users and half the groups belong to the discovered vendor**, as required.

## Discovering Northwind Traders

`keywords.csv` = `Northwind`, `Northwind Traders`, `NWT`.
`known.csv` = `Project Atlas Team` (corp). `exclude.csv` = `All Staff` (apac),
`Globex All Employees` (dmz).

### Expected result (the oracle)

Running the engine over this fixture for Northwind surfaces **exactly the 10
Northwind-related groups** and none of the decoys. Each row below is what
`Show-FixtureDiscovery.ps1` prints:

| Group | Domain | Band | Why it matched |
|-------|--------|------|----------------|
| Northwind Traders Admins | corp (A, `OU=Northwind`) | High | Name + container keyword, owner (jbrooks), members |
| NWT Application Owners | corp (A) | High | Name + container keyword; **member via cross-domain foreign-SID** (ohaddad from dmz) |
| Northwind Support | emea (A) | High | Name + container keyword, owner — **but a Distribution group** (dropped by `-SecurityGroupsOnly`) |
| NWT Finance Sync | emea (A) | High | Name + container keyword, members |
| Logistics Integration RW | corp (**flat** `OU=Groups`) | High | Description keyword + description-mentions-user (jbrooks) + owner + members — surfaces despite no vendor container or keyword in the name |
| Traders Data Feed | apac (B, flat) | High | Description keyword + members (name alone does *not* match) |
| APAC Vendor Access | apac (B, flat) | High | Description keyword + member + **contains another vendor group** (Traders Data Feed) |
| Northwind RW | dmz (B, flat) | High | Name keyword + members |
| Global Logistics Stewards | corp (flat) | **Medium** | **Closure only** — no direct signal; promoted because it contains "Northwind Traders Admins" |
| Project Atlas Team | corp (flat) | **Confirmed** | In `known.csv` — no automatic signal otherwise |

**Correctly NOT surfaced** (precision): all Contoso, Fabrikam and Globex-only
groups (e.g. `Contoso Service Desk`, `Fabrikam Plant Ops`, `Globex IT Admins`).

**Excluded** (would otherwise surface as Low because they contain Northwind
members): `All Staff` (apac) and `Globex All Employees` (dmz).

### Patterns exercised

Name keyword · container/OU keyword · description keyword · description-mentions-user ·
managedBy/owner · member-is-vendor-user · nested-vendor-group closure · known list ·
exclude list · cross-domain foreign-security-principal (SID) resolution ·
security-vs-distribution filtering · flat-vs-foldered directory structures.

## Using it

```powershell
# End-to-end demo (no live AD):
pwsh -NoProfile -File ./tests/fixtures/Show-FixtureDiscovery.ps1

# In your own test/script, get a Get-AdDiscoveryData-shaped object from the fixture:
. ./tests/_TestHelpers.ps1                 # loads the engine functions
. ./tests/fixtures/Import-DiscoveryFixture.ps1
$data = Get-FixtureDiscoveryData               # .Groups, .VendorUsers, .DnIndex, .InputData
```

To regenerate after editing the data tables in `New-DiscoveryFixture.ps1`:

```powershell
pwsh -NoProfile -File ./tests/fixtures/New-DiscoveryFixture.ps1
```
