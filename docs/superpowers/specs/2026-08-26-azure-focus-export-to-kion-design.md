# Azure FOCUS billing export to Kion — Design

**Status:** Implemented. Revised 2026-09-01 to match what was measured against
real Azure and real Kion during implementation — see `docs/VERIFICATION.md`.
Where this document and the code disagreed, the code was right; the sections
below have been corrected rather than left teaching the wrong shape.
**Date:** 2026-08-26

## Purpose

Onboard Azure customer tenants to Kion using **native Azure Cost Management FOCUS
exports**. For each tenant the tool stands up storage, creates the FOCUS exports,
creates the app registration Kion authenticates as, and registers the Kion
billing source that reads the exported data.

It runs over a list of tenants, logging in to each one interactively, and reports
what succeeded and what did not.

## Non-goals

- **No relationship to the Partner Center converter.** This is a separate
  pipeline that happens to borrow shell code. It does not read Partner Center,
  does not run the converter, and does not share configuration with it.
- No container image, no ACI, no scheduler of our own. Azure runs the export on
  its own schedule; we only create it.
- No cross-tenant writes. Azure writes each export into that tenant's own
  storage, so there is no shared writer identity and no consent flow.

## Background

Kion reads FOCUS data from blob storage: the payer carries `UseFOCUSReports`, and
the storage coordinates (`FOCUSStoragePrimaryEndpoint`, `FOCUSStorageContainer`,
`FOCUSStoragePrefix`) tell it where to look. That is the same contract the
Partner Center pipeline satisfies by generating FOCUS CSVs; here Azure generates
them instead.

Three facts from the Azure docs shape the design:

- The **FOCUS dataset combines actual and amortized costs** (`BilledCost` and
  `EffectiveCost` columns). `ActualCost` and `AmortizedCost` are *sibling*
  dataset types, not options within FOCUS, and Kion's FOCUS ingestion cannot read
  them. This tool creates `FocusCost` exports only; choosing actual vs amortized
  is a Kion-side spend data type setting.
- **`az costmanagement export create` cannot create FOCUS exports** — the CLI
  accepts only `ActualCost`, `AmortizedCost`, and `Usage`. Exports are created
  with `az rest --method put`, which reuses the CLI's existing auth.
- **Management group scope is not supported for FOCUS exports.** Subscription
  scope always works; MCA additionally supports billing account and billing
  profile scope.

References: [Retrieve large cost datasets recurringly with exports](https://learn.microsoft.com/en-us/azure/cost-management-billing/costs/ingest-azure-usage-at-scale),
[Exports - Create Or Update](https://learn.microsoft.com/en-us/rest/api/cost-management/exports/create-or-update?view=rest-cost-management-2025-03-01),
[Tutorial: create and manage exports](https://learn.microsoft.com/en-us/azure/cost-management-billing/costs/tutorial-improved-exports),
[FOCUS dataset schema](https://learn.microsoft.com/en-us/azure/cost-management-billing/dataset-schema/cost-usage-details-focus),
[Configure scopes for FinOps hubs](https://learn.microsoft.com/en-us/cloud-computing/finops/toolkit/hubs/configure-scopes).

## Environments

Both Azure Gov and Commercial are supported. Commercial means **MCA**
specifically; Gov covers CSP Gov and MCA Gov. The cloud and billing model
together select endpoints and the Kion account type:

| Setting | Gov | Commercial |
|---|---|---|
| `az cloud` | `AzureUSGovernment` | `AzureCloud` |
| ARM endpoint | `management.usgovcloudapi.net` | `management.azure.com` |
| Graph endpoint | `graph.microsoft.us` | `graph.microsoft.com` |
| Blob suffix | `core.usgovcloudapi.net` | `core.windows.net` |
| Login authority | `login.microsoftonline.us` | `login.microsoftonline.com` |

Kion account type ids (`src/domain/account_type.go`), selected by billing model
and cloud:

| Billing model | Commercial | Gov |
|---|---|---|
| MCA | `16` (AzureMCA) | `18` (AzureMCAGov) |
| CSP | `3` (AzureCSPStandard) | `11` (AzureCSPGov) |

Endpoints are read from `az cloud show` where possible rather than hardcoded, so
a cloud we have not listed still resolves correctly.

## Flow

`onboard-tenant.sh` does one tenant, and every step is independently
re-runnable so a partial failure is resumed by running it again:

1. **Log in.** `az login --tenant <TENANT_ID>` interactively, skipped when that
   tenant is already the active context. Verify the resulting context matches the
   configured tenant before doing anything else.
2. **Ensure storage.** Resource group, storage account, and container, created
   only if missing. Storage account settings match what we use elsewhere:
   `Standard_LRS`, `StorageV2`, Hot, HTTPS-only, TLS 1.2, no public blob access.
3. **Resolve export scopes.** `billingAccount` by default (MCA/EA), which
   creates one export covering everything under that scope. `billingProfile`
   works the same way. `subscription` scope stays available but is only correct
   for a tenant with exactly one subscription — see §Error handling. When
   subscription scope has to discover the tenant's subscriptions, the list is
   filtered by tenant id: `az account list` returns every subscription in the
   CLI profile for the cloud, across every tenant signed into it, and
   `onboard-all` signs into each tenant in turn.
4. **Create FOCUS exports.** One `FocusCost` export per scope, via `az rest`,
   with `rootFolderPath` set to `<prefix>/<scope-leaf>`. Azure then writes to

       <rootFolderPath>/<export-name>/<YYYYMMDD-YYYYMMDD>/<runstamp>/<run-guid>/

   inserting the `<export-name>` level itself. Kion computes its search path as
   `<FOCUSStoragePrefix>/<YYYYMMDD>-<YYYYMMDD>/`, so the prefix the billing
   source must receive is `<rootFolderPath>/<export-name>` — never the bare
   `rootFolderPath`, which lists zero blobs. `create-focus-exports.sh` is the
   only place that knows both halves, and reports the value as `KION_PREFIX=`
   on stdout; no other script reconstructs it.
5. **Create the Kion app.** App registration, service principal, secret, Graph
   permissions with admin consent, Owner on the management group, and
   Storage Blob Data Reader on the container. Borrowed near-verbatim.
6. **Create the Kion billing source**, pointed at the endpoint, container, and
   prefix, using the account type from the table above. Write the returned payer
   id back into the tenant's config file.
7. **Report** one result line for the tenant.

`onboard-all` loops every `tenants/*.env` through this. Each tenant runs as its
own process (`onboard-tenant.sh` is a separate script), so no tenant can leak a
variable into the next.

## Repo layout

```
Makefile                       onboard / onboard-all / exports / kion-source / status
.env.example                   Kion connection, cloud, billing model, FOCUS version, schedule
tenants/
  example.env.example          per-tenant template
scripts/
  onboard-tenant.sh            the whole flow for one tenant
  ensure-storage.sh            resource group + storage account + container   (borrowed)
  create-focus-exports.sh      scope resolution + FOCUS export creation       (new)
  create-kion-app.sh           app registration + permissions                 (borrowed)
  kion-create-billing-source.sh  Kion payer creation                          (borrowed, de-routed)
  lib/common.sh                logging, env parsing, cloud resolution, summary
docs/
README.md
```

Borrowed scripts arrive stripped of Partner Center concepts: no partner app, no
consent of a shared identity, no routing JSON, no cross-tenant write.

## Configuration

**`.env`** — one Kion, one set of defaults:

```sh
KION_HOST=
KION_API_KEY=
KION_API_BASE=/api
AZURE_CLOUD=AzureUSGovernment      # default; per-tenant override expected
BILLING_MODEL=MCA                  # default; per-tenant override expected
FOCUS_VERSION=1.0
EXPORT_RECURRENCE=Daily
EXPORT_TIMEFRAME=MonthToDate
EXPORT_PREFIX=focus
EXPORT_SCOPE=billingAccount        # default; subscription only for a
                                   # single-subscription tenant
EXPORT_API_VERSION=2025-03-01      # Cost Management Exports api-version
```

`AZURE_CLOUD` and `BILLING_MODEL` are defaults, not constraints: Gov and
Commercial tenants are expected to be onboarded from the same checkout, so both
are overridable per tenant and the tenant value wins. The same is true of
`EXPORT_PREFIX`, `EXPORT_SCOPE`, `EXPORT_API_VERSION`, `FOCUS_VERSION`,
`EXPORT_RECURRENCE` and `EXPORT_TIMEFRAME`.

Every one of these uses capture-first precedence: read the inherited value into
a local first, then let a non-empty tenant-file value win. Reading the tenant
file straight into the variable would stomp an inherited value with an empty
string before the fallback ever saw it.

**`tenants/<name>.env`** — one file per tenant:

```sh
TENANT_ID=
AZURE_CLOUD=                       # overrides the global default
BILLING_MODEL=                     # MCA or CSP; overrides the global default
RESOURCE_GROUP=
STORAGE_ACCOUNT=
CONTAINER=
LOCATION=
EXPORT_SCOPE=                      # billingAccount (default) / billingProfile /
                                   # subscription (single-subscription tenants only)
BILLING_SCOPE_ID=                  # required for the non-subscription scopes
SUBSCRIPTIONS=                     # optional allowlist; empty means all in the tenant
MANAGEMENT_GROUP=                  # empty means the tenant root group
KION_PAYER_ID=                     # written back once the billing source exists
```

Per-tenant values override the globals. Files are parsed, never sourced, and one
tenant is loaded at a time so two tenants cannot clobber each other's values.

## Export payload

`PUT {arm}/{scope}/providers/Microsoft.CostManagement/exports/{name}?api-version=2025-03-01`
with a body carrying `definition.type: FocusCost`,
`dataSet.configuration.dataVersion` set
from `FOCUS_VERSION`, `granularity: Daily`, `format: Csv`, partitioning enabled,
`dataOverwriteBehavior` set to keep previous files, and a destination pointing at
the tenant's storage account, container, and prefix.

Schedule is two distinct fields, not one: `schedule.recurrence` from
`EXPORT_RECURRENCE` and `definition.timeframe` from `EXPORT_TIMEFRAME`. The
default pairing is a daily run over month-to-date costs.

The api-version matters and is not free to choose: `2023-08-01` and earlier have
no `FocusCost` member in their `ExportType` enum and cannot create a FOCUS export
at all. `2025-03-01` is the default and was confirmed working on Gov (live GET
and PUT). It is overridable per tenant via `EXPORT_API_VERSION` because Azure
moves the available versions over time.

Export names are deterministic and derived from the scope, so re-running updates
the existing export rather than creating duplicates. The scope's leaf is
sanitised (an MCA billing account id carries `:` and `_`, which a resource name
cannot) and truncated to 64 characters, and `rootFolderPath` uses the same
sanitised leaf, so the reported `KION_PREFIX` is always what Azure will actually
write to rather than a guess rebuilt from the raw leaf.

## Error handling

Each tenant runs as its own process; a failure is recorded and the loop
continues — what keeps one tenant's failure from ending the run is the `if`
around the call, not process isolation.
Within a tenant, the steps are ordered so a failure leaves nothing half-wired:
storage before exports, exports before the billing source, so Kion is never
pointed at a container that has no export feeding it.

The run ends with a summary table (tenant, storage, exports, app, billing source,
status — plus a trailing free-text detail column, because a `warn` cell is
useless without naming what needs attention) and exits non-zero if any tenant
failed. Because continue-on-error means nobody watches every line, this summary
is the primary output and gets built first.

Cells are `ok`, `warn`, `failed`, `skipped`, or `-` when the run never reached
that step. `onboard-tenant.sh` reports each finished step as a
`STEP=<name>:<state>` line on stdout as it goes, which is what lets a row still
show partial progress for a run that died partway through.

`warn` exists because "the tenant is onboarded, but the job is not finished" is
a real state and must not be summarised as `ok`. Its one case today: a tenant
whose `KION_PAYER_ID` is already set. Kion has no API for editing an existing
Azure billing source — only its UI — so a re-onboard cannot repair a stale FOCUS
prefix and can only report it. `kion-create-billing-source.sh` signals this with
a documented exit 3, distinct from both success and failure. A `warn` does not
make the run exit non-zero; only `failed` does.

One export per billing source is a hard constraint. A Kion billing source is
created at the tenant level with one set of tenant credentials and one FOCUS
endpoint/container/prefix, and Kion keeps only the single newest blob ending in
`manifest.json` beneath its search path. So `subscription` scope resolving to
more than one subscription is refused before anything is created: N exports
would produce N manifests, Kion would ingest exactly one, and the other
subscriptions' costs would vanish with no error anywhere.

## Testing

Stub `az` and `curl` on `PATH` and assert on the calls they receive. No real
Azure or Kion calls in tests. Cases:

- fresh tenant: storage created, one export created, app created, billing source
  created, payer id written back
- everything already exists: no duplicate creation, and the run reports `warn`
  (not `ok`) for the billing source, because its prefix was deliberately not
  updated
- mid-flow failure: recorded, loop continues, summary reports it, exit non-zero
- Gov vs Commercial: correct endpoints, blob suffix, and Kion account type
- MCA billing-account/profile scope: one export covering the whole scope
- multi-subscription `subscription` scope: refused before anything is created
- the prefix printed in the operator-facing banner is byte-identical to the one
  posted to Kion
- subscription discovery filters by tenant id, from a CLI profile holding more
  than one tenant's subscriptions
- `onboard-all.sh` exercised against the real `onboard-tenant.sh`, not only a
  fake, so the seam between them is covered

Plus `bash -n` on every script and shellcheck where available, both wired into
`make test` (`tests/test-shell-syntax.sh`), skipping shellcheck cleanly when it
is not installed.

Success-path tests must assert the exit code explicitly. These test files run
without `set -e`, so an invocation that fails is otherwise reported as passing —
which is exactly what happened when the `curl` stub's default response body was
invalid JSON.

## Agreement types this tool can onboard

| Agreement | Tenant-wide FOCUS scope | Supported |
|---|---|---|
| MCA | billing account / billing profile | Yes |
| EA | billing account (enrollment) | Yes |
| CSP (Microsoft Partner Agreement) | Customer scope only | Only with exactly one subscription |

Azure offers no billing-account or billing-profile FOCUS export under a
Microsoft Partner Agreement. A CSP customer tenant's only tenant-wide scope is
Customer scope, which lives in the *partner's* tenant and needs Admin agent or
billing admin there — not reachable from a sign-in to the customer tenant. A CSP
customer with more than one subscription therefore cannot be onboarded here;
that case belongs to the Partner Center converter pipeline.

## Verified during implementation

Full results in `docs/VERIFICATION.md`; the load-bearing ones:

- **api-version:** `2025-03-01` accepted on Gov, live GET and PUT. `2023-08-01`
  and earlier cannot create a FOCUS export at all.
- **Blob layout, measured:** Azure writes to
  `<rootFolderPath>/<export-name>/<YYYYMMDD-YYYYMMDD>/<runstamp>/<run-guid>/manifest.json`.
- **Kion's ingestion — the opposite of what this document originally guessed.**
  It does *not* fan out across nested per-subscription prefixes. It computes
  `<FOCUSStoragePrefix>/<YYYYMMDD>-<YYYYMMDD>/`, lists beneath it recursively,
  and keeps only the **single newest** blob ending in `manifest.json`. One
  billing source therefore consumes exactly one export. Listing at
  `focus/20260901-20260930/` returned 0 blobs; at
  `focus/<sub-id>/<export-name>/20260901-20260930/` it returned the manifest and
  the CSV. That is why the prefix Kion receives must be
  `<rootFolderPath>/<export-name>`, and why multi-subscription `subscription`
  scope is refused rather than allowed to silently drop money.
- **Run now is required.** A new export's `nextRunTimeEstimate` was ~20 hours
  out, so the tool triggers `POST <export>/run` (confirmed working on Gov). A
  failed kick-off is a warning: the export still runs on its schedule.

## Still unverified

- Commercial cloud (`AzureCloud`) end to end.
- Billing-scope exports against a real MCA billing account — the Gov test tenant
  is an EA with no reachable billing account.
- Kion actually ingesting from one of these containers.
- The MCA payer-creation payload, which is modelled on the CSP shape.
