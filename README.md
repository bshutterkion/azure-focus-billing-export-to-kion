# Azure FOCUS billing export to Kion

Onboards Azure tenants to Kion using native Cost Management **FOCUS exports**.
For each tenant it creates the storage, the FOCUS exports, the app registration
Kion authenticates as, and the Kion billing source that reads the data.

Unrelated to the Partner Center converter: nothing here reads Partner Center or
runs a converter. Azure writes the exports into the tenant's own storage and
Kion reads them from there, so there is no cross-tenant write and no shared
writer identity.

## Setup

    cp .env.example .env                       # Kion host, API key, defaults
    cp tenants/example.env.example tenants/<name>.env

## Onboarding

    make onboard TENANT=<name>

The run signs in interactively to that tenant as it reaches that step (skipped
if the CLI is already pointed at it), so there is no separate `az login` step
to run first — doing that yourself risks leaving the CLI logged into the wrong
tenant when the run gets there. Pass `--skip-login` directly to
`scripts/onboard-tenant.sh` to skip the sign-in when a session is already
pointed at the right tenant.

The run then checks that the CLI's active tenant *and* active cloud both match
the tenant file, and stops before creating anything if either does not. Both
checks run under `--skip-login` too: that flag skips the sign-in, not the
verification. The cloud check earns its place because nothing here runs
`az cloud set` — the CLI's cloud decides which ARM, Graph and storage endpoints
the run uses, while `AZURE_CLOUD` in the tenant file decides the Kion account
type (MCA vs MCA Gov, CSP vs CSP Gov). Left to disagree, a run puts the right
data under the wrong account type and reports success. Fix it with
`az cloud set --name <cloud>`, then sign in again.

Or every tenant in `tenants/`, continuing past failures and printing a summary:

    make onboard-all

The summary has one row per tenant with a cell for each step — storage,
exports, app, billing source — then an overall status and a detail note:

    TENANT      STORAGE  EXPORTS  APP      BILLING SOURCE  STATUS  DETAIL
    acme        ok       ok       ok       ok              ok      onboarded
    contoso     ok       ok       ok       warn            warn    payer 42 exists; set focus_storage_prefix=... in the Kion UI
    fabrikam    ok       failed   -        -               failed  see output above

`warn` means the tenant is onboarded but something still needs a human, and the
run still exits 0. Today that is one case: a tenant whose `KION_PAYER_ID` is
already set. Kion has no API for editing an existing Azure billing source, so a
re-run cannot repair its FOCUS prefix — the detail column names the payer id and
the prefix to set by hand. Only `failed` makes the run exit non-zero.

A re-run of an already-onboarded tenant also mints a fresh client secret on the
app registration (appended, so nothing existing is invalidated) that this run
cannot deliver to Kion. It is written to `kion-app-<app-id>-credential.env` and
called out on stderr; paste it into the Kion UI alongside the prefix.

Each run logs in to the tenant, creates the resource group / storage account /
container if missing, creates a single FOCUS export covering the whole tenant at
billing-account scope, creates the Kion app with the permissions Kion needs,
and registers the billing source — recording the payer id back into the
tenant's file so a later run leaves it alone.

One export per billing source is a hard constraint, not a preference: a Kion
billing source is added at the tenant level and carries exactly one FOCUS
storage endpoint, container and prefix, and Kion ingests only the single newest
manifest found under that prefix. A tenant that produced one export per
subscription would therefore have all but one subscription's costs silently
dropped, which is why `subscription` scope is refused for a tenant with more
than one subscription.

## Which tenants this tool can onboard

| Agreement | Tenant-wide FOCUS scope | Supported here |
|---|---|---|
| MCA | billing account / billing profile | Yes |
| EA | billing account (enrollment) | Yes |
| CSP (Microsoft Partner Agreement) | Customer scope only | Only if the tenant has exactly one subscription |

Azure does not offer billing-account or billing-profile FOCUS exports under a
Microsoft Partner Agreement. A CSP customer tenant's only tenant-wide scope is
Customer scope, which lives in the *partner's* tenant and needs Admin agent or
billing admin there — not reachable from a sign-in to the customer tenant. So a
CSP customer with more than one subscription cannot be onboarded with this tool;
that case is what the Partner Center converter pipeline exists for.

Every step is idempotent, so re-running after a failure resumes rather than
duplicating.

### Resuming a single step

If only part of a tenant's onboarding needs to be re-run:

    make exports TENANT=<name>       # re-create only the FOCUS exports
    make kion-source TENANT=<name>   # re-register only the Kion billing source

### Checking on tenants

    make status

Prints each tenant's cloud, billing model, and whether `KION_PAYER_ID` is set,
by reading `tenants/*.env` directly. It makes no Azure or Kion API calls.

## Requirements in each tenant

- **Application Administrator** to create the app and grant admin consent
- **Contributor** or Owner to create the resource group and storage account
- **Owner** or **User Access Administrator** on the management group. This is
  the one that usually blocks a first run: subscription Owner does not carry up
  to the management group. Either point `MANAGEMENT_GROUP` at a group you own,
  or have a Global Admin enable "Access management for Azure resources" and
  sign in again.

## Environment variables

`.env` holds Kion connection details and shared defaults; `tenants/<name>.env`
holds per-tenant values, which override the `.env` default whenever the tenant
file sets them non-empty. The values that work that way are exactly:

`AZURE_CLOUD`, `BILLING_MODEL`, `EXPORT_PREFIX`, `EXPORT_SCOPE`,
`EXPORT_API_VERSION`, `FOCUS_VERSION`, `EXPORT_RECURRENCE`, `EXPORT_TIMEFRAME`.

`KION_HOST`, `KION_API_KEY` and `KION_API_BASE` are `.env`-only: one Kion serves
every tenant. `RESOURCE_GROUP`, `STORAGE_ACCOUNT`, `CONTAINER`, `LOCATION`,
`BILLING_SCOPE_ID`, `SUBSCRIPTIONS`, `MANAGEMENT_GROUP` and `KION_PAYER_ID` are
per-tenant only.

See `.env.example` and `tenants/example.env.example` for the full list,
including `EXPORT_API_VERSION` — the Cost Management Exports API version, which
Azure moves over time and which must be new enough to accept the FOCUS dataset
type (`2023-08-01` and earlier cannot).

`.env` values are also parsed by `make` itself (`-include .env`), so avoid `#`
and `$` in values there — see the warning at the top of `.env.example`.

## Tests

    make test

Tests stub `az` and `curl` on `PATH` and assert on the calls made. Nothing
touches Azure or Kion. The suite also runs `bash -n` over every script and,
when `shellcheck` is on `PATH`, `shellcheck -S warning`; it skips the
shellcheck test cleanly when it is not installed.
