# Azure FOCUS billing export to Kion — Design

**Status:** Approved, ready for an implementation plan
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
3. **Resolve export scopes.** Subscription scope by default: enumerate the
   tenant's subscriptions. `EXPORT_SCOPE=billingProfile` or `billingAccount` (MCA
   only) instead creates one export covering everything under that scope.
4. **Create FOCUS exports.** One `FocusCost` export per scope, via `az rest`,
   writing to `<container>/<prefix>/<scope-id>/`.
5. **Create the Kion app.** App registration, service principal, secret, Graph
   permissions with admin consent, Owner on the management group, and
   Storage Blob Data Reader on the container. Borrowed near-verbatim.
6. **Create the Kion billing source**, pointed at the endpoint, container, and
   prefix, using the account type from the table above. Write the returned payer
   id back into the tenant's config file.
7. **Report** one result line for the tenant.

`onboard-all` loops every `tenants/*.env` through this, each in a subshell.

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
```

`AZURE_CLOUD` and `BILLING_MODEL` are defaults, not constraints: Gov and
Commercial tenants are expected to be onboarded from the same checkout, so both
are overridable per tenant and the tenant value wins.

**`tenants/<name>.env`** — one file per tenant:

```sh
TENANT_ID=
AZURE_CLOUD=                       # overrides the global default
BILLING_MODEL=                     # MCA or CSP; overrides the global default
RESOURCE_GROUP=
STORAGE_ACCOUNT=
CONTAINER=
LOCATION=
EXPORT_SCOPE=subscription          # or billingProfile / billingAccount (MCA)
BILLING_SCOPE_ID=                  # required for the non-subscription scopes
SUBSCRIPTIONS=                     # optional allowlist; empty means all in the tenant
MANAGEMENT_GROUP=                  # empty means the tenant root group
KION_PAYER_ID=                     # written back once the billing source exists
```

Per-tenant values override the globals. Files are parsed, never sourced, and one
tenant is loaded at a time so two tenants cannot clobber each other's values.

## Export payload

`PUT {arm}/{scope}/providers/Microsoft.CostManagement/exports/{name}` with a body
carrying `definition.type: FocusCost`, `dataSet.configuration.dataVersion` set
from `FOCUS_VERSION`, `granularity: Daily`, `format: Csv`, partitioning enabled,
`dataOverwriteBehavior` set to keep previous files, and a destination pointing at
the tenant's storage account, container, and prefix.

Schedule is two distinct fields, not one: `schedule.recurrence` from
`EXPORT_RECURRENCE` and `definition.timeframe` from `EXPORT_TIMEFRAME`. The
default pairing is a daily run over month-to-date costs.

Export names are deterministic and derived from the scope, so re-running updates
the existing export rather than creating duplicates.

## Error handling

Each tenant runs in a subshell; a failure is recorded and the loop continues.
Within a tenant, the steps are ordered so a failure leaves nothing half-wired:
storage before exports, exports before the billing source, so Kion is never
pointed at a container that has no export feeding it.

The run ends with a summary table (tenant, storage, exports, app, billing source,
status) and exits non-zero if any tenant failed. Because continue-on-error means
nobody watches every line, this summary is the primary output and gets built
first.

## Testing

Stub `az` and `curl` on `PATH` and assert on the calls they receive. No real
Azure or Kion calls in tests. Cases:

- fresh tenant: storage created, exports created per subscription, app created,
  billing source created, payer id written back
- everything already exists: no duplicate creation, exits clean
- mid-flow failure: recorded, loop continues, summary reports it, exit non-zero
- Gov vs Commercial: correct endpoints, blob suffix, and Kion account type
- MCA billing-profile scope: one export instead of per-subscription

Plus `bash -n` on every script and shellcheck where available.

## To verify during implementation

- Exact api-version for FOCUS exports, and that the same version works on Gov.
- That Kion's FOCUS ingestion recurses into nested per-subscription prefixes
  under the configured prefix. The Partner Center path relies on nested
  directories, so it likely does, but it must be confirmed before this layout is
  committed to.
- Whether the export needs a "Run now" to produce data promptly, or whether
  waiting for the first scheduled run is acceptable.
- The exact Kion payer-creation payload for MCA, which may differ from the CSP
  shape the borrowed script sends.
