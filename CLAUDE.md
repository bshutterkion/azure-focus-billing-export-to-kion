# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Bash tooling that onboards Azure customer tenants to Kion using native Azure
Cost Management **FOCUS exports**. Per tenant it creates storage, one FOCUS
export, the Azure AD app registration Kion authenticates as, and the Kion
billing source that reads the exported blobs.

Read `README.md` for operator-facing usage. The design spec and the live
verification log under `docs/` are deliberately untracked — they may be present
in a working copy but are not in a fresh clone, so treat `README.md` and the
code as the only sources of truth. Where code and spec ever disagreed, the code
was right.

## Commands

    make onboard TENANT=<name>      # one tenant end to end
    make onboard-all                # every tenants/*.env, continues past failures
    make exports TENANT=<name>      # re-run only the FOCUS export step
    make kion-source TENANT=<name>  # re-run only the app + billing-source steps
    make status                     # read tenants/*.env; no Azure or Kion calls
    make test                       # whole suite

Run a single test file directly (each is standalone and self-reporting):

    bash tests/test-onboard-tenant.sh

`make test` also runs `bash -n` over every script, plus `shellcheck -S warning
-x` when shellcheck is on `PATH` (skipped cleanly if not). Install shellcheck
locally — a lot of this code's correctness lives in quoting.

Requires `az`, `jq`, and bash. Target bash **3.2** (macOS ships it): no
`mapfile`, no associative arrays, no `${var,,}`. Existing code reads command
output with `while IFS= read -r` loops for this reason.

## Architecture

One controller, four idempotent step scripts, one sourced library:

- `scripts/onboard-tenant.sh` — the controller. Resolves config, verifies the
  session, then calls the step scripts in order: storage → exports → app →
  billing source. `--only exports` / `--only kion-source` skip subsets.
- `scripts/ensure-storage.sh` — resource group, storage account, container.
- `scripts/create-focus-exports.sh` — the FOCUS export, via `az rest --method
  put` (the `az costmanagement` CLI cannot create FocusCost exports).
- `scripts/create-kion-app.sh` — app registration, service principal, Graph
  permissions, role assignments, client secret.
- `scripts/kion-create-billing-source.sh` — `POST /v1/payer/standalone` to Kion,
  then writes `KION_PAYER_ID` back into the tenant file.
- `scripts/onboard-all.sh` — loops tenant files, renders the summary table.
- `scripts/lib/common.sh` — logging, `cfg_get`, `resolve_cloud`,
  `kion_account_type`, summary accumulation. Sourced everywhere; no import-time
  side effects.

### stdout is a data channel

Every script keeps **progress and diagnostics on stderr** and puts only
machine-readable data on stdout. Callers parse that stdout (`APP_ID=`,
`TENANT_DOMAIN=`, `CREDENTIAL_FILE=`, `KION_PREFIX=`, the bare blob endpoint).
Adding a stray `echo` to stdout breaks the caller silently. `onboard-tenant.sh`
additionally emits `STEP=<name>:<state>` and at most one `STEP_DETAIL=` line,
which `onboard-all.sh` reads back to build per-step summary cells — so a run
that dies partway still produces an accurate row.

`require_value` in the controller exists because an empty value parsed out of
another script's stdout would otherwise flow into the Kion call and register a
broken billing source.

### Config precedence: capture-first

`.env` holds shared defaults, `tenants/<name>.env` holds per-tenant values, and
a tenant value wins **only when set non-empty**. Implement this with the
capture-first idiom already used throughout `onboard-tenant.sh`:

    inherited_x="${X:-}"
    tf_x="$(cfg_get "$TENANT_FILE" X)"
    X="${tf_x:-${inherited_x:-<default>}}"

Reading the tenant file straight into the variable stomps an inherited value
with an empty string. That bug class — a per-tenant override silently ignored,
or an inherited default silently erased — has recurred here more than once.

`cfg_get` reads a key with `sed` rather than sourcing the file, so tenant files
are never executed. `.env` is *also* parsed by make (`-include .env`), so `#`
and `$` in its values get mangled; the warning at the top of `.env.example`
covers it.

### Two independent sources of truth for "which cloud"

`resolve_cloud` derives ARM/Graph/blob/AD endpoints from the CLI's **active**
cloud (`az cloud show`), while `AZURE_CLOUD` from config picks the **Kion
account type id** (`kion_account_type`: MCA 16, MCA Gov 18, CSP 3, CSP Gov 11).
Nothing here runs `az cloud set`, and `onboard-all.sh` loops Gov and Commercial
tenants from one checkout. Left to disagree, a run creates correct Gov storage
and registers it in Kion as Commercial — right data, wrong account type, no
error. Hence the hard check in `onboard-tenant.sh`; it deliberately runs even
under `--skip-login`, which skips the sign-in, not the verification.

### One export per billing source is a hard constraint

A Kion billing source carries exactly one FOCUS endpoint/container/prefix, and
Kion ingests only the single newest manifest under that prefix. So:

- `EXPORT_SCOPE=billingAccount` is the default — one export covering the whole
  tenant. `subscription` scope is refused when it resolves to more than one
  subscription, because the extra subscriptions' costs would vanish with no
  error.
- Billing scopes need MCA or EA. A CSP (Microsoft Partner Agreement) customer
  tenant with more than one subscription **cannot** be onboarded here.

### KION_PREFIX comes from create-focus-exports.sh, never string concatenation

Azure inserts the export name as a folder below `rootFolderPath`, so the prefix
Kion needs is `<rootFolderPath>/<export-name>`. The bare `rootFolderPath` lists
zero blobs. Only `create-focus-exports.sh` knows both halves (including the
sanitized/truncated scope leaf), which is why `--only kion-source` re-derives it
via `--print-only` instead of rebuilding the path. The same value must reach
both the Kion API call and the framed operator banner `create-kion-app.sh`
prints — those two diverging was this project's headline defect.

### Exit code 3 means "onboarded, but a human is needed"

Kion has no API for editing an existing Azure billing source, so a re-run of an
already-onboarded tenant cannot repair its prefix.
`kion-create-billing-source.sh` exits **3** in that case; the controller turns it
into `billing-source warn` plus a `STEP_DETAIL` naming the payer id and prefix,
and `summary_exit_code` keeps the overall run at exit 0. Only `failed` is
non-zero. Do not collapse `warn` into `ok` — a run that did not finish the job
must never be summarised as plain success.

## Tests

`tests/lib/harness.sh` puts recording stubs for `az` and `curl` on `PATH`
(`tests/stubs/`), so nothing touches Azure or Kion. Tests declare fake CLI
responses with `az_state KEY value` and assert on recorded calls
(`assert_az_called`, `assert_curl_stdin_contains`, `assert_file_contains`, …).
`AZ_FAIL_MATCH` forces a matching `az` call to fail; `CURL_BODY` / `CURL_CODE`
shape the Kion response. `onboard-all.sh` honours `ONBOARD_TENANT_BIN` so its
tests can stub the controller.

Test files run **without `set -e`**, so a script's success-path exit code has to
be captured and asserted explicitly (`rc=$?`, then `assert_rc_zero`). Never
`|| true` — that once hid every happy-path test exiting 1.

Stubs only prove the code sends what it was told to send. A stub `az` accepts
any URL and any payload, so stub-green says nothing about whether Azure or Kion
accepts it. Several defects here shipped past a green suite for exactly that
reason — a prefix Kion could never match, an api-version that cannot create
FOCUS exports at all. Treat "tests pass" as necessary, not sufficient, and
verify anything new against a real tenant before believing it.

## Conventions

- Comments explain **why**, especially the non-obvious guard. Most guards here
  exist because their absence produced a silently-wrong result (right data,
  wrong place; missing money; success reported for an incomplete run). Preserve
  that reasoning when editing, and write it for new guards.
- Secrets never go on argv: the Kion call passes the API key header and request
  body through a `curl --config -` file on stdin, and body temp files are
  `chmod 600` before being written and removed via an `EXIT` trap. Credential
  files are `kion-app-<app-id>-credential.env`, mode 0600, gitignored.
- Tenant-file writes are atomic (`mktemp` + `sed` + `mv`), preserve the original
  mode, and ensure a trailing newline before appending.
- Prefer failing loudly over proceeding on an empty or malformed value.
- Commit messages: `type(scope): imperative summary`, e.g. `fix(azure): …`,
  `docs(azure): …`.
