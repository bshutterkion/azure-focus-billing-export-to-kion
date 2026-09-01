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
`scripts/onboard-tenant.sh` if a session is already pointed at the right
tenant and you want to bypass the check.

Or every tenant in `tenants/`, continuing past failures and printing a summary:

    make onboard-all

Each run logs in to the tenant, creates the resource group / storage account /
container if missing, creates one FOCUS export per subscription (or one at a
billing scope for MCA), creates the Kion app with the permissions Kion needs,
and registers the billing source — recording the payer id back into the
tenant's file so a later run leaves it alone.

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
file sets them non-empty. See `.env.example` and `tenants/example.env.example`
for the full list, including `EXPORT_API_VERSION` — the Cost Management
Exports API version, which Azure moves over time and which must be new enough
to accept the FOCUS dataset type (`2023-08-01` and earlier cannot).

`.env` values are also parsed by `make` itself (`-include .env`), so avoid `#`
and `$` in values there — see the warning at the top of `.env.example`.

## Tests

    make test

Tests stub `az` and `curl` on `PATH` and assert on the calls made. Nothing
touches Azure or Kion.
