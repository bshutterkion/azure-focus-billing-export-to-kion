# Live verification status

What has been confirmed against real Azure, what has not, and how to close the
gaps. Stub tests prove the code sends what we told it to send; only a real run
proves Azure and Kion accept it. Everything in "Not yet verified" is a real risk,
not a formality.

## Confirmed against real Azure

Run on 2026-09-01 against the Kion Gov DS EA subscription
`35c7ce00-2824-4bab-a5f4-918e6e2f068b` (cloud `AzureUSGovernment`). Resources
were created and deleted afterwards.

| What | Result |
|---|---|
| Exports api-versions available on Gov | `2026-06-01`, `2025-03-01`, `2024-08-01`, … `2023-08-01` |
| `2025-03-01` accepted on Gov | Yes, live `az rest` GET and PUT both succeeded |
| `definition.type: FocusCost` accepted | Yes, at `2025-03-01` |
| Payload stored verbatim | `dataVersion 1.0`, `granularity Daily`, `timeframe MonthToDate`, `format Csv`, `partitionData true`, `dataOverwriteBehavior CreateNewReport` |
| `ensure-storage.sh` against real Gov | Exit 0; stdout carried only the blob endpoint, diagnostics on stderr |
| Gov blob endpoint suffix | `core.usgovcloudapi.net`, as derived |
| Where Azure actually writes | `<rootFolderPath>/<export-name>/<YYYYMMDD-YYYYMMDD>/<runstamp>/<run-guid>/manifest.json` — Azure inserts `<export-name>` itself |
| Files produced | `manifest.json` and `part_1_0001.csv` |
| Gov manifest filename | `manifest.json`, not `_manifest.json`; Kion's suffix match handles both |
| Time to first scheduled run | `nextRunTimeEstimate` was ~20 hours out, so a run-now is required for prompt onboarding |
| `POST <export>/run` on Gov | Works; appears in `runHistory` as `executionType: OnDemand`, status `Completed` |

Two defects were found this way and fixed:

- The prefix given to Kion could never match. Listing at
  `focus/20260901-20260930/` returned **0 blobs**; listing at
  `focus/<sub-id>/<export-name>/20260901-20260930/` returned both files. Kion
  must receive `<rootFolderPath>/<export-name>`.
- Kion keeps only the single newest `manifest.json` under the prefix
  (`getPartitionedManifestBlob`), so one billing source can consume only one
  export. Subscription-scope exports on a multi-subscription tenant would have
  silently dropped every subscription but one.

## Not yet verified — do these on the first real customer tenant

### 1. The cloud guard's happy path

`onboard-tenant.sh` refuses to run when the CLI's active cloud is not the
tenant's configured `AZURE_CLOUD`. It exists because the two are independent
sources of truth: endpoints come from `az cloud show` (the active cloud) while
`AZURE_CLOUD` selects the Kion account type id, so a mismatch would create
correct Gov storage and then register the source as AzureMCA (16) instead of
AzureMCAGov (18) — right data, wrong account type, no error.

Only its rejection path has been exercised, with stubs. It now stands between the
operator and every later step, so confirm on the first real run that a correctly
configured tenant passes it rather than being blocked by a name-spelling
mismatch. Cloud names are compared exactly and must be spelled as `az` reports
them (`az account show --query environmentName -o tsv`).

A Commercial run is **not** tracked separately here. Gov is the more restrictive
cloud and passed live; endpoints are read from `az cloud show` at runtime, so
there are no Commercial constants to get wrong; and item 2 below will exercise
Commercial in passing.

### 2. Billing-scope exports (the one that matters most)

The tool now defaults to `EXPORT_SCOPE=billingAccount` so a single export covers
every subscription in the tenant. **This path has never run.** The Gov test
tenant is an Enterprise Agreement with no reachable billing account
(`az billing account list` returns empty), so it could not be exercised.

Confirm on a real MCA tenant:

    az billing account list -o table          # must return the account
    # set BILLING_SCOPE_ID in tenants/<name>.env, then:
    make exports TENANT=<name>

Then check the export was created at the billing scope and that its
`rootFolderPath` contains no subscription id.

### 3. Kion actually ingests the data

The blob path has been proven to match what Kion searches for, by reading
Kion's `MonthlyPrefix` and comparing against real blobs. Kion has never been
pointed at one of these containers.

After `make onboard`, wait for a run to complete, then confirm spend appears on
the billing source. If it does not, check the payer's `FOCUSStoragePrefix`
against the actual blob path first — that is the failure this design is most
exposed to.

### 4. The MCA payer payload

`kion-create-billing-source.sh` sends a payload modelled on the CSP shape, with
the account type chosen by billing model and cloud (MCA 16, MCA Gov 18,
CSP 3, CSP Gov 11). The MCA variants have not been exercised against a real
Kion. Confirm Kion accepts the payload and that both credential tests pass on
the created source.

### 5. Export name length cap

`MAX_EXPORT_NAME_LEN` is set to 64 as a conservative guess; no published Azure
limit was found. A billing-account leaf sanitises to a long name, so if Azure
rejects it the error will be loud at creation time. Adjust the constant if a
real billing-scope run rejects the name.

## Permissions the operator needs in each tenant

- **Application Administrator** to create the app registration and grant admin
  consent.
- **Contributor** or Owner to create the resource group and storage account.
- **Owner** or **User Access Administrator** on the management group. This is
  the one that blocks a first run in practice: subscription Owner does not carry
  up to the management group. Either point `MANAGEMENT_GROUP` at a group you own,
  or have a Global Admin enable "Access management for Azure resources" and sign
  in again.
- For `EXPORT_SCOPE=billingAccount` or `billingProfile`, a billing role that can
  read the billing account. Without it the export creation fails at that scope.

## Tenants this tool cannot onboard

A Kion billing source is added at the tenant level and carries exactly one FOCUS
storage endpoint, container and prefix, and Kion ingests only the newest manifest
under that prefix. One billing source therefore consumes exactly one export.

Azure offers a tenant-wide FOCUS export scope only for MCA (billing account /
billing profile) and EA (enrollment). Under a Microsoft Partner Agreement the
only tenant-wide scope is Customer scope, which lives in the partner's tenant
and requires Admin agent or billing admin there, so it is not reachable from a
sign-in to the customer tenant.

Consequence: a CSP customer tenant with more than one subscription cannot be
onboarded with this tool. It will hit the multi-subscription guard, correctly.
That case belongs to the Partner Center converter pipeline.

References:
[Tutorial: create and manage exports](https://learn.microsoft.com/en-us/azure/cost-management-billing/costs/tutorial-improved-exports),
[Understand and work with scopes](https://learn.microsoft.com/en-us/azure/cost-management-billing/costs/understand-work-scopes),
[Cost Management for partners](https://learn.microsoft.com/en-us/azure/cost-management-billing/costs/get-started-partners).

## Defects found by verification rather than by tests

Recorded because each one passed a green stub suite. A stub `az` accepts any URL
and any payload, so it can only prove the code sends what it was told to send.

| Defect | How it would have shown up | Found by |
|---|---|---|
| api-version `2023-08-01` cannot create FOCUS exports | every export creation fails on the first real tenant | reading Microsoft's docs |
| Kion was given the bare prefix, not `<rootFolderPath>/<export-name>` | onboarding reports success; Kion finds nothing, forever | comparing real blob paths against Kion's own `MonthlyPrefix` |
| Subscription-scope exports on a multi-subscription tenant | one subscription's costs ingest, the rest vanish silently | reading Kion's `getPartitionedManifestBlob` |
| The operator banner printed the bare prefix | operator pastes the 0-blob value into Kion by hand | final whole-branch review |
| `curl` stub's default body was invalid JSON | every happy-path controller test exited 1 and reported ok | final whole-branch review |
| `AZURE_CLOUD` never checked against the CLI's active cloud | correct Gov storage, billing source registered as Commercial | questioning why a checklist item existed |
| Appending a payer id to a file with no trailing newline | cloud silently becomes garbage and the payer id is invisible, so the next run creates a duplicate billing source | writing the first test for that branch |

The pattern: every layer that was asserted against held, and every layer that was
not — the operator-facing output, the success path's own exit code, the file
format of a hand-edited config — did not.
