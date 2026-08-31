# Azure FOCUS Billing Export to Kion — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A bash + make tool that, for each Azure tenant in a list, creates native Cost Management FOCUS exports, the app registration Kion authenticates as, and the Kion billing source that reads the exported data.

**Architecture:** One script does one tenant idempotently (`onboard-tenant.sh`); a driver loops tenants with interactive `az login`, continuing past failures and printing a summary. All Azure work is `az` / `az rest`; Kion work is `curl`. No image, no scheduler of our own.

**Tech Stack:** bash 3.2-compatible shell, GNU make, Azure CLI, jq, curl. Tests use stub `az`/`curl` binaries on `PATH` — no network, no real Azure or Kion.

**Spec:** `docs/superpowers/specs/2026-08-26-azure-focus-export-to-kion-design.md`

## Global Constraints

- **bash 3.2 compatible.** macOS ships 3.2. No `mapfile`, no `declare -A`, no `${arr[@]}` on a possibly-empty array under `set -u` (use `${arr[@]+"${arr[@]}"}`).
- **Every script starts `set -euo pipefail`** and is executable.
- **Config files are parsed, never sourced.** Nothing in a `.env` may execute.
- **One tenant's config is loaded at a time.** Two tenants must not clobber each other's values.
- **Only `FocusCost` exports.** Never `ActualCost`, `AmortizedCost`, or `Usage` — Kion cannot read them.
- **Never hardcode cloud endpoints when `az cloud show` can supply them.** Fall back to the documented literals only when it returns nothing.
- Secrets (`.env`, `tenants/*.env`, `*credential*.env`) are gitignored before any file that could contain one is created.
- Storage accounts are created as `Standard_LRS`, `StorageV2`, `Hot`, HTTPS-only, TLS1_2, no public blob access.
- Idempotent throughout: re-running any script must not duplicate an Azure resource or a Kion payer.

**Kion account type ids** (from `src/domain/account_type.go`): MCA commercial `16`, MCA gov `18`, CSP commercial `3`, CSP gov `11`.

---

## File Structure

| File | Responsibility |
|---|---|
| `.gitignore` | keep secrets out of git |
| `scripts/lib/common.sh` | logging, env parsing, cloud/type resolution, summary rows |
| `scripts/ensure-storage.sh` | resource group + storage account + container |
| `scripts/create-focus-exports.sh` | scope resolution + FOCUS export creation |
| `scripts/create-kion-app.sh` | app registration, permissions, secret |
| `scripts/kion-create-billing-source.sh` | Kion payer creation + payer id write-back |
| `scripts/onboard-tenant.sh` | one tenant, end to end |
| `scripts/onboard-all.sh` | loop tenants, continue on error, summary |
| `Makefile` | entry points |
| `tests/lib/harness.sh` | stub setup, assertions |
| `tests/stubs/az`, `tests/stubs/curl` | recording stubs |
| `tests/test-*.sh` | one file per script under test |
| `tests/run-tests.sh` | runner |

---

## Task 1: Foundation — gitignore, test harness, `common.sh`

**Files:**
- Create: `.gitignore`, `scripts/lib/common.sh`, `tests/lib/harness.sh`, `tests/stubs/az`, `tests/stubs/curl`, `tests/run-tests.sh`, `tests/test-common.sh`

**Interfaces:**
- Consumes: nothing
- Produces: `log_info/log_warn/log_err`, `cfg_get FILE KEY`, `resolve_cloud`, `kion_account_type MODEL CLOUD`, `summary_add TENANT STATUS DETAIL`, `summary_print`, `summary_exit_code`

- [ ] **Step 1: Create `.gitignore` first**

```
.env
tenants/*.env
!tenants/*.env.example
*credential*.env
.DS_Store
```

- [ ] **Step 2: Create the recording stubs**

`tests/stubs/az`:
```bash
#!/bin/bash
# Recording stub for az. Logs every invocation to $AZ_LOG and answers from
# $AZ_STATE (key=value lines). Set AZ_FAIL_MATCH to a regex to force failure.
echo "$*" >> "$AZ_LOG"
state() { sed -n "s/^$1=//p" "$AZ_STATE" 2>/dev/null | tail -1; }
if [ -n "${AZ_FAIL_MATCH:-}" ] && printf '%s' "$*" | grep -qE "$AZ_FAIL_MATCH"; then
  echo "stub az: forced failure" >&2; exit 1
fi
case "$*" in
  "account show --query tenantId"*)  echo "$(state TENANT_ID)" ;;
  "account show --query id"*)        echo "$(state SUBSCRIPTION_ID)" ;;
  "account list"*)                   echo "$(state SUBSCRIPTIONS)" | tr ',' '\n' ;;
  "cloud show"*"resourceManager"*)   echo "$(state ARM_ENDPOINT)" ;;
  "cloud show"*"microsoftGraphResourceId"*) echo "$(state GRAPH_ENDPOINT)" ;;
  "cloud show"*"storageEndpoint"*)   echo "$(state BLOB_SUFFIX)" ;;
  "cloud show"*"activeDirectory"*)   echo "$(state AD_ENDPOINT)" ;;
  "group show"*)                     [ "$(state RG_EXISTS)" = 1 ] || exit 1 ;;
  "storage account show"*"--query id"*) echo "/subscriptions/s/rg/r/sa" ;;
  "storage account show"*"primaryEndpoints.blob"*) echo "$(state BLOB_ENDPOINT)" ;;
  "storage account show"*)           [ "$(state SA_EXISTS)" = 1 ] || exit 1 ;;
  "ad app list"*)                    echo "$(state APP_ID)" ;;
  "ad app create"*)                  echo "new-app-id" ;;
  "ad sp list"*)                     echo "$(state SP_OID)" ;;
  "ad sp create"*)                   echo "new-sp-oid" ;;
  "ad app credential reset"*)        echo '{"password":"stub-secret"}' ;;
  "ad sp show --id 00000003"*)       echo '{"appRoles":[{"value":"User.Read.All","id":"r1"},{"value":"Group.Read.All","id":"r2"}],"oauth2PermissionScopes":[{"value":"User.Read","id":"s1"},{"value":"Directory.Read.All","id":"s2"}]}' ;;
  "rest "*)                          echo '{"id":"/exports/stub"}' ;;
  *) : ;;
esac
exit 0
```

`tests/stubs/curl`:
```bash
#!/bin/bash
# Recording stub for curl. Logs the invocation and emits $CURL_BODY then the
# status code on its own line, matching -w '\n%{http_code}'.
echo "$*" >> "$CURL_LOG"
printf '%s\n%s' "${CURL_BODY:-{\"data\":{\"id\":1}\}}" "${CURL_CODE:-201}"
```

- [ ] **Step 3: Create `tests/lib/harness.sh`**

```bash
#!/bin/bash
# Test harness: stub az/curl on PATH, record calls, assert on them.
HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_DIR="$(cd "$HARNESS_DIR/.." && pwd)"
TESTS_RUN=0; TESTS_FAILED=0; CURRENT_TEST=""

setup_test() {
  CURRENT_TEST="$1"; TESTS_RUN=$((TESTS_RUN+1)); TEST_FAILED=0
  TEST_TMP="$(mktemp -d)"
  export TEST_TMP AZ_LOG="$TEST_TMP/az.log" CURL_LOG="$TEST_TMP/curl.log" AZ_STATE="$TEST_TMP/az.state"
  : > "$AZ_LOG"; : > "$CURL_LOG"; : > "$AZ_STATE"
  mkdir -p "$TEST_TMP/bin"
  cp "$HARNESS_DIR/stubs/az" "$HARNESS_DIR/stubs/curl" "$TEST_TMP/bin/"
  chmod +x "$TEST_TMP/bin/az" "$TEST_TMP/bin/curl"
  export PATH="$TEST_TMP/bin:$PATH"
}

teardown_test() {
  if [ "$TEST_FAILED" -eq 0 ]; then echo "  ok   $CURRENT_TEST"
  else echo "  FAIL $CURRENT_TEST"; TESTS_FAILED=$((TESTS_FAILED+1)); fi
  rm -rf "$TEST_TMP"
}

az_state()  { echo "$1=$2" >> "$AZ_STATE"; }
fail()      { echo "       $*" >&2; TEST_FAILED=1; }
assert_eq() { [ "$1" = "$2" ] || fail "expected '$2', got '$1'"; }
assert_az_called()     { grep -qE -- "$1" "$AZ_LOG"   || fail "no az call matching: $1"; }
assert_az_not_called() { grep -qE -- "$1" "$AZ_LOG"   && fail "unexpected az call: $1"; return 0; }
assert_curl_called()   { grep -qE -- "$1" "$CURL_LOG" || fail "no curl call matching: $1"; }
assert_file_contains() { grep -qE -- "$2" "$1" || fail "$1 missing: $2"; }
finish_tests() { echo; echo "$TESTS_RUN run, $TESTS_FAILED failed"; [ "$TESTS_FAILED" -eq 0 ]; }
```

- [ ] **Step 4: Create `tests/run-tests.sh`**

```bash
#!/bin/bash
set -uo pipefail
cd "$(dirname "$0")"
rc=0
for t in test-*.sh; do
  echo "== $t"
  bash "$t" || rc=1
done
exit "$rc"
```

- [ ] **Step 5: Write the failing tests for `common.sh`**

`tests/test-common.sh`:
```bash
#!/bin/bash
set -uo pipefail
. "$(dirname "$0")/lib/harness.sh"
. "$REPO_DIR/scripts/lib/common.sh"

setup_test "cfg_get reads a key and strips quotes"
printf 'TENANT_ID="abc-123"\nCONTAINER=focus\n' > "$TEST_TMP/t.env"
assert_eq "$(cfg_get "$TEST_TMP/t.env" TENANT_ID)" "abc-123"
assert_eq "$(cfg_get "$TEST_TMP/t.env" CONTAINER)" "focus"
assert_eq "$(cfg_get "$TEST_TMP/t.env" MISSING)" ""
teardown_test

setup_test "cfg_get does not execute file contents"
printf 'EVIL=$(touch %s/pwned)\n' "$TEST_TMP" > "$TEST_TMP/e.env"
cfg_get "$TEST_TMP/e.env" EVIL >/dev/null
[ -f "$TEST_TMP/pwned" ] && fail "config file was executed"
teardown_test

setup_test "resolve_cloud uses az cloud show values"
az_state ARM_ENDPOINT "https://management.usgovcloudapi.net/"
az_state GRAPH_ENDPOINT "https://graph.microsoft.us/"
az_state BLOB_SUFFIX "core.usgovcloudapi.net"
resolve_cloud
assert_eq "$ARM_ENDPOINT" "https://management.usgovcloudapi.net"
assert_eq "$BLOB_SUFFIX" "core.usgovcloudapi.net"
teardown_test

setup_test "kion_account_type maps model and cloud"
assert_eq "$(kion_account_type MCA AzureCloud)" "16"
assert_eq "$(kion_account_type MCA AzureUSGovernment)" "18"
assert_eq "$(kion_account_type CSP AzureCloud)" "3"
assert_eq "$(kion_account_type CSP AzureUSGovernment)" "11"
teardown_test

setup_test "summary reports failures and exit code"
summary_reset
summary_add tenant-a ok "3 exports"
summary_add tenant-b failed "storage"
out="$(summary_print)"
case "$out" in *tenant-a*ok*) : ;; *) fail "missing tenant-a row" ;; esac
case "$out" in *tenant-b*failed*) : ;; *) fail "missing tenant-b row" ;; esac
assert_eq "$(summary_exit_code)" "1"
summary_reset
summary_add tenant-c ok "done"
assert_eq "$(summary_exit_code)" "0"
teardown_test

finish_tests
```

- [ ] **Step 6: Run the tests to verify they fail**

Run: `bash tests/run-tests.sh`
Expected: FAIL — `scripts/lib/common.sh` does not exist.

- [ ] **Step 7: Implement `scripts/lib/common.sh`**

```bash
#!/bin/bash
# Shared helpers. Sourced by every script; defines no side effects on import.

log_info() { echo "==> $*" >&2; }
log_warn() { echo "    WARNING: $*" >&2; }
log_err()  { echo "ERROR: $*" >&2; }

# cfg_get FILE KEY — read one value without executing the file. Last
# assignment wins; surrounding quotes and trailing whitespace are stripped.
cfg_get() {
  [ -f "$1" ] || return 0
  sed -n "s/^[[:space:]]*$2=//p" "$1" | tail -1 \
    | sed 's/^"\(.*\)"$/\1/; s/^'"'"'\(.*\)'"'"'$/\1/; s/[[:space:]]*$//'
}

# resolve_cloud — set ARM_ENDPOINT, GRAPH_ENDPOINT, BLOB_SUFFIX, AD_ENDPOINT
# from the active az cloud, falling back to documented literals per cloud.
resolve_cloud() {
  local cloud="${AZURE_CLOUD:-AzureCloud}"
  ARM_ENDPOINT="$(az cloud show --query 'endpoints.resourceManager' -o tsv 2>/dev/null | sed 's:/*$::')"
  GRAPH_ENDPOINT="$(az cloud show --query 'endpoints.microsoftGraphResourceId' -o tsv 2>/dev/null | sed 's:/*$::')"
  BLOB_SUFFIX="$(az cloud show --query 'suffixes.storageEndpoint' -o tsv 2>/dev/null)"
  AD_ENDPOINT="$(az cloud show --query 'endpoints.activeDirectory' -o tsv 2>/dev/null | sed 's:/*$::')"
  if [ "$cloud" = "AzureUSGovernment" ]; then
    : "${ARM_ENDPOINT:=https://management.usgovcloudapi.net}"
    : "${GRAPH_ENDPOINT:=https://graph.microsoft.us}"
    : "${BLOB_SUFFIX:=core.usgovcloudapi.net}"
    : "${AD_ENDPOINT:=https://login.microsoftonline.us}"
  else
    : "${ARM_ENDPOINT:=https://management.azure.com}"
    : "${GRAPH_ENDPOINT:=https://graph.microsoft.com}"
    : "${BLOB_SUFFIX:=core.windows.net}"
    : "${AD_ENDPOINT:=https://login.microsoftonline.com}"
  fi
  export ARM_ENDPOINT GRAPH_ENDPOINT BLOB_SUFFIX AD_ENDPOINT
}

# kion_account_type MODEL CLOUD — Kion account type id.
kion_account_type() {
  case "$1:$2" in
    MCA:AzureUSGovernment) echo 18 ;;
    MCA:*)                 echo 16 ;;
    CSP:AzureUSGovernment) echo 11 ;;
    CSP:*)                 echo 3  ;;
    *) log_err "unknown billing model '$1'"; return 1 ;;
  esac
}

# Summary rows accumulate in a temp file so subshells can append to them.
summary_reset() { SUMMARY_FILE="${SUMMARY_FILE:-$(mktemp)}"; : > "$SUMMARY_FILE"; export SUMMARY_FILE; }
summary_add()   { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$SUMMARY_FILE"; }
summary_print() {
  echo ""
  printf '%-24s %-8s %s\n' "TENANT" "STATUS" "DETAIL"
  printf '%-24s %-8s %s\n' "------" "------" "------"
  while IFS=$'\t' read -r t s d; do printf '%-24s %-8s %s\n' "$t" "$s" "$d"; done < "$SUMMARY_FILE"
}
summary_exit_code() { grep -q $'\tfailed\t' "$SUMMARY_FILE" && echo 1 || echo 0; }
```

- [ ] **Step 8: Run the tests to verify they pass**

Run: `bash tests/run-tests.sh`
Expected: PASS — `5 run, 0 failed`.

- [ ] **Step 9: Commit**

```bash
chmod +x tests/run-tests.sh tests/stubs/az tests/stubs/curl
git add .gitignore scripts/lib/common.sh tests/
git commit -m "feat: shared helpers and stub-based test harness"
```

---

## Task 2: `ensure-storage.sh`

**Files:**
- Create: `scripts/ensure-storage.sh`, `tests/test-ensure-storage.sh`

**Interfaces:**
- Consumes: `cfg_get`, `log_*`, `resolve_cloud` from `scripts/lib/common.sh`
- Produces: script accepting `--resource-group --storage-account --container [--location]`; prints the blob endpoint on stdout

- [ ] **Step 1: Write the failing tests**

`tests/test-ensure-storage.sh`:
```bash
#!/bin/bash
set -uo pipefail
. "$(dirname "$0")/lib/harness.sh"
S="$REPO_DIR/scripts/ensure-storage.sh"

setup_test "creates rg, storage and container when missing"
az_state RG_EXISTS 0; az_state SA_EXISTS 0
az_state BLOB_ENDPOINT "https://sa.blob.core.usgovcloudapi.net/"
bash "$S" --resource-group rg1 --storage-account sa1 --container focus --location usgovvirginia >/dev/null
assert_az_called "group create --name rg1 --location usgovvirginia"
assert_az_called "storage account create --name sa1"
assert_az_called "Standard_LRS"
assert_az_called "storage container create"
teardown_test

setup_test "creates nothing when everything exists"
az_state RG_EXISTS 1; az_state SA_EXISTS 1
az_state BLOB_ENDPOINT "https://sa.blob.core.usgovcloudapi.net/"
bash "$S" --resource-group rg1 --storage-account sa1 --container focus >/dev/null
assert_az_not_called "group create"
assert_az_not_called "storage account create"
teardown_test

setup_test "fails clearly when rg is missing and no location given"
az_state RG_EXISTS 0
if bash "$S" --resource-group rg1 --storage-account sa1 --container focus >/dev/null 2>"$TEST_TMP/err"; then
  fail "expected non-zero exit"
fi
assert_file_contains "$TEST_TMP/err" "location"
teardown_test

setup_test "prints the blob endpoint on stdout"
az_state RG_EXISTS 1; az_state SA_EXISTS 1
az_state BLOB_ENDPOINT "https://sa.blob.core.usgovcloudapi.net/"
out="$(bash "$S" --resource-group rg1 --storage-account sa1 --container focus 2>/dev/null)"
assert_eq "$out" "https://sa.blob.core.usgovcloudapi.net/"
teardown_test

finish_tests
```

- [ ] **Step 2: Run to verify they fail**

Run: `bash tests/test-ensure-storage.sh`
Expected: FAIL — script does not exist.

- [ ] **Step 3: Implement `scripts/ensure-storage.sh`**

```bash
#!/bin/bash
#
# ensure-storage.sh — resource group, storage account and container for a
# tenant's FOCUS exports. Creates only what is missing. Prints the blob
# endpoint on stdout; all progress goes to stderr.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

RG=""; STORAGE=""; CONTAINER=""; LOCATION=""
while [ $# -gt 0 ]; do
  case "$1" in
    --resource-group)  RG="$2"; shift 2 ;;
    --storage-account) STORAGE="$2"; shift 2 ;;
    --container)       CONTAINER="$2"; shift 2 ;;
    --location)        LOCATION="$2"; shift 2 ;;
    *) log_err "unknown argument: $1"; exit 2 ;;
  esac
done
[ -n "$RG" ] && [ -n "$STORAGE" ] && [ -n "$CONTAINER" ] || {
  log_err "--resource-group, --storage-account and --container are required"; exit 2; }

if az group show --name "$RG" >/dev/null 2>&1; then
  log_info "resource group '$RG' exists"
  RG_LOCATION="$(az group show --name "$RG" --query location -o tsv)"
else
  [ -n "$LOCATION" ] || { log_err "resource group '$RG' does not exist and --location was not given"; exit 1; }
  log_info "creating resource group '$RG' in $LOCATION"
  az group create --name "$RG" --location "$LOCATION" --only-show-errors >/dev/null
  RG_LOCATION="$LOCATION"
fi

if az storage account show --name "$STORAGE" --resource-group "$RG" >/dev/null 2>&1; then
  log_info "storage account '$STORAGE' exists"
else
  log_info "creating storage account '$STORAGE' in ${LOCATION:-$RG_LOCATION}"
  az storage account create --name "$STORAGE" --resource-group "$RG" \
    --location "${LOCATION:-$RG_LOCATION}" \
    --sku Standard_LRS --kind StorageV2 --access-tier Hot \
    --https-only true --min-tls-version TLS1_2 --allow-blob-public-access false \
    --only-show-errors >/dev/null
fi

# AAD auth first; fall back to account key, which only needs listKeys. Control
# plane Owner does not confer blob data access, so a freshly created account
# usually needs the key path here.
log_info "ensuring container '$CONTAINER'"
az storage container create --account-name "$STORAGE" --name "$CONTAINER" \
    --auth-mode login --only-show-errors >/dev/null 2>&1 \
  || az storage container create --account-name "$STORAGE" --name "$CONTAINER" \
    --resource-group "$RG" --auth-mode key --only-show-errors >/dev/null 2>&1 \
  || log_warn "could not create container '$CONTAINER'; it may already exist"

az storage account show --name "$STORAGE" --resource-group "$RG" --query "primaryEndpoints.blob" -o tsv
```

- [ ] **Step 4: Run to verify they pass**

Run: `bash tests/test-ensure-storage.sh`
Expected: PASS — `4 run, 0 failed`.

- [ ] **Step 5: Commit**

```bash
chmod +x scripts/ensure-storage.sh
git add scripts/ensure-storage.sh tests/test-ensure-storage.sh
git commit -m "feat: ensure resource group, storage account and container"
```

---

## Task 3: `create-focus-exports.sh`

**Files:**
- Create: `scripts/create-focus-exports.sh`, `tests/test-create-focus-exports.sh`

**Interfaces:**
- Consumes: `resolve_cloud`, `log_*` from `scripts/lib/common.sh`
- Produces: script accepting `--storage-account-id --container --prefix [--scope subscription|billingProfile|billingAccount] [--billing-scope-id ID] [--subscriptions "a b"] [--focus-version V] [--recurrence R] [--timeframe T] [--api-version V]`; prints one line per export created

- [ ] **Step 1: Write the failing tests**

`tests/test-create-focus-exports.sh`:
```bash
#!/bin/bash
set -uo pipefail
. "$(dirname "$0")/lib/harness.sh"
S="$REPO_DIR/scripts/create-focus-exports.sh"
SAID="/subscriptions/s1/resourceGroups/rg/providers/Microsoft.Storage/storageAccounts/sa"

setup_test "creates one export per subscription"
bash "$S" --storage-account-id "$SAID" --container focus --prefix focus \
  --subscriptions "sub-a sub-b" >/dev/null
assert_az_called "rest --method put"
assert_az_called "subscriptions/sub-a/providers/Microsoft.CostManagement/exports"
assert_az_called "subscriptions/sub-b/providers/Microsoft.CostManagement/exports"
teardown_test

setup_test "export body requests FocusCost, not actual or amortized"
bash "$S" --storage-account-id "$SAID" --container focus --prefix focus \
  --subscriptions "sub-a" >/dev/null
assert_file_contains "$TEST_TMP/az.log" "FocusCost"
grep -qE "ActualCost|AmortizedCost" "$TEST_TMP/az.log" && fail "must not request legacy dataset types"
teardown_test

setup_test "body carries version, recurrence and timeframe"
bash "$S" --storage-account-id "$SAID" --container focus --prefix focus \
  --subscriptions "sub-a" --focus-version 1.2-preview --recurrence Daily --timeframe MonthToDate >/dev/null
assert_file_contains "$TEST_TMP/az.log" "1.2-preview"
assert_file_contains "$TEST_TMP/az.log" "MonthToDate"
teardown_test

setup_test "prefix nests per subscription"
bash "$S" --storage-account-id "$SAID" --container focus --prefix focus \
  --subscriptions "sub-a" >/dev/null
assert_file_contains "$TEST_TMP/az.log" "focus/sub-a"
teardown_test

setup_test "billingProfile scope creates a single export"
bash "$S" --storage-account-id "$SAID" --container focus --prefix focus \
  --scope billingProfile --billing-scope-id "/providers/Microsoft.Billing/billingAccounts/ba/billingProfiles/bp" >/dev/null
assert_az_called "billingProfiles/bp/providers/Microsoft.CostManagement/exports"
assert_eq "$(grep -c 'rest --method put' "$TEST_TMP/az.log")" "1"
teardown_test

setup_test "enumerates subscriptions when none are given"
az_state SUBSCRIPTIONS "sub-x,sub-y"
bash "$S" --storage-account-id "$SAID" --container focus --prefix focus >/dev/null
assert_az_called "account list"
assert_az_called "subscriptions/sub-x/providers"
assert_az_called "subscriptions/sub-y/providers"
teardown_test

setup_test "non-subscription scope requires a billing scope id"
if bash "$S" --storage-account-id "$SAID" --container focus --prefix focus \
   --scope billingProfile >/dev/null 2>"$TEST_TMP/err"; then fail "expected non-zero exit"; fi
assert_file_contains "$TEST_TMP/err" "billing-scope-id"
teardown_test

finish_tests
```

- [ ] **Step 2: Run to verify they fail**

Run: `bash tests/test-create-focus-exports.sh`
Expected: FAIL — script does not exist.

- [ ] **Step 3: Implement `scripts/create-focus-exports.sh`**

```bash
#!/bin/bash
#
# create-focus-exports.sh — create Azure Cost Management FOCUS exports.
#
# FocusCost only: the FOCUS dataset already carries both actual (BilledCost)
# and amortized (EffectiveCost) costs, and Kion's FOCUS ingestion cannot read
# the ActualCost/AmortizedCost dataset types.
#
# `az costmanagement export create` cannot create FOCUS exports (it accepts
# only ActualCost, AmortizedCost and Usage), so this uses `az rest`, which
# reuses the CLI's existing auth.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

STORAGE_ID=""; CONTAINER=""; PREFIX="focus"
SCOPE="subscription"; BILLING_SCOPE_ID=""; SUBSCRIPTIONS=""
FOCUS_VERSION="1.0"; RECURRENCE="Daily"; TIMEFRAME="MonthToDate"
API_VERSION="2023-08-01"

while [ $# -gt 0 ]; do
  case "$1" in
    --storage-account-id) STORAGE_ID="$2"; shift 2 ;;
    --container)          CONTAINER="$2"; shift 2 ;;
    --prefix)             PREFIX="$2"; shift 2 ;;
    --scope)              SCOPE="$2"; shift 2 ;;
    --billing-scope-id)   BILLING_SCOPE_ID="$2"; shift 2 ;;
    --subscriptions)      SUBSCRIPTIONS="$2"; shift 2 ;;
    --focus-version)      FOCUS_VERSION="$2"; shift 2 ;;
    --recurrence)         RECURRENCE="$2"; shift 2 ;;
    --timeframe)          TIMEFRAME="$2"; shift 2 ;;
    --api-version)        API_VERSION="$2"; shift 2 ;;
    *) log_err "unknown argument: $1"; exit 2 ;;
  esac
done
[ -n "$STORAGE_ID" ] && [ -n "$CONTAINER" ] || {
  log_err "--storage-account-id and --container are required"; exit 2; }

resolve_cloud

# Scopes to export at. Management group scope is not supported for FOCUS.
SCOPES=""
case "$SCOPE" in
  subscription)
    if [ -z "$SUBSCRIPTIONS" ]; then
      SUBSCRIPTIONS="$(az account list --query "[].id" -o tsv | tr '\n' ' ')"
    fi
    for s in $SUBSCRIPTIONS; do
      [ -n "$s" ] && SCOPES="$SCOPES subscriptions/$s"
    done
    ;;
  billingProfile|billingAccount)
    [ -n "$BILLING_SCOPE_ID" ] || { log_err "--billing-scope-id is required for scope '$SCOPE'"; exit 2; }
    SCOPES="${BILLING_SCOPE_ID#/}"
    ;;
  *) log_err "unknown scope '$SCOPE'"; exit 2 ;;
esac
[ -n "$SCOPES" ] || { log_err "no scopes resolved; nothing to export"; exit 1; }

START="$(date -u +%Y-%m-%d)T00:00:00Z"
END="$(date -u -v+5y +%Y-%m-%d 2>/dev/null || date -u -d '+5 years' +%Y-%m-%d)T00:00:00Z"

for scope in $SCOPES; do
  leaf="${scope##*/}"
  name="kion-focus-${leaf}"
  body="$(jq -nc \
    --arg rec "$RECURRENCE" --arg from "$START" --arg to "$END" \
    --arg sid "$STORAGE_ID" --arg cont "$CONTAINER" --arg root "$PREFIX/$leaf" \
    --arg tf "$TIMEFRAME" --arg ver "$FOCUS_VERSION" \
    '{properties:{
        schedule:{status:"Active", recurrence:$rec,
                  recurrencePeriod:{from:$from, to:$to}},
        format:"Csv",
        deliveryInfo:{destination:{resourceId:$sid, container:$cont, rootFolderPath:$root}},
        definition:{type:"FocusCost", timeframe:$tf,
                    dataSet:{granularity:"Daily", configuration:{dataVersion:$ver}}},
        partitionData:true,
        dataOverwriteBehavior:"CreateNewReport",
        compressionMode:"None"}}')"
  url="${ARM_ENDPOINT}/${scope}/providers/Microsoft.CostManagement/exports/${name}?api-version=${API_VERSION}"
  log_info "creating FOCUS export '$name' at $scope"
  if az rest --method put --url "$url" --body "$body" --only-show-errors >/dev/null; then
    echo "$name"
  else
    log_err "failed to create export '$name' at $scope"
    exit 1
  fi
done
```

- [ ] **Step 4: Run to verify they pass**

Run: `bash tests/test-create-focus-exports.sh`
Expected: PASS — `7 run, 0 failed`.

- [ ] **Step 5: Commit**

```bash
chmod +x scripts/create-focus-exports.sh
git add scripts/create-focus-exports.sh tests/test-create-focus-exports.sh
git commit -m "feat: create FocusCost exports per subscription or billing scope"
```

---

## Task 4: `create-kion-app.sh`

Borrowed from `kion-focus-converter/deploy/azure-partner-center/azure/arm/scripts/create-customer-kion-app.sh`, stripped of Partner Center concepts (no shared partner app, no consent of a foreign identity).

**Files:**
- Create: `scripts/create-kion-app.sh`, `tests/test-create-kion-app.sh`

**Interfaces:**
- Consumes: `resolve_cloud`, `log_*`
- Produces: script accepting `--resource-group --storage-account --container [--app-name N] [--app-id ID] [--management-group ID] [--kion-url URL] [--secret-years N]`; writes `kion-app-<appId>-credential.env`; prints `APP_ID=<id>` and `TENANT_DOMAIN=<domain>` on stdout

- [ ] **Step 1: Write the failing tests**

`tests/test-create-kion-app.sh`:
```bash
#!/bin/bash
set -uo pipefail
. "$(dirname "$0")/lib/harness.sh"
S="$REPO_DIR/scripts/create-kion-app.sh"

setup_test "creates app, sp, secret, graph perms, mg owner and blob reader"
az_state APP_ID ""; az_state SP_OID ""; az_state TENANT_ID "t-1"
cd "$TEST_TMP"
bash "$S" --resource-group rg --storage-account sa --container focus >/dev/null
assert_az_called "ad app create"
assert_az_called "sign-in-audience AzureADMyOrg"
assert_az_called "ad sp create"
assert_az_called "ad app credential reset"
assert_az_called "ad app permission add"
assert_az_called "ad app permission admin-consent"
assert_az_called "role assignment create.*Owner.*managementGroups"
assert_az_called "Storage Blob Data Reader"
teardown_test

setup_test "reuses an existing app instead of creating a second"
az_state APP_ID "existing-app"; az_state SP_OID "existing-sp"; az_state TENANT_ID "t-1"
cd "$TEST_TMP"
bash "$S" --resource-group rg --storage-account sa --container focus >/dev/null
assert_az_not_called "ad app create"
assert_az_called "ad app credential reset"
teardown_test

setup_test "appends the secret rather than replacing existing credentials"
az_state APP_ID "existing-app"; az_state SP_OID "existing-sp"; az_state TENANT_ID "t-1"
cd "$TEST_TMP"
bash "$S" --resource-group rg --storage-account sa --container focus >/dev/null
assert_az_called "credential reset.*--append"
teardown_test

setup_test "writes a 0600 credential file and prints the app id"
az_state APP_ID "app-42"; az_state SP_OID "sp-1"; az_state TENANT_ID "t-1"
cd "$TEST_TMP"
out="$(bash "$S" --resource-group rg --storage-account sa --container focus 2>/dev/null)"
case "$out" in *APP_ID=app-42*) : ;; *) fail "app id not printed" ;; esac
f="$TEST_TMP/kion-app-app-42-credential.env"
[ -f "$f" ] || fail "credential file not written"
assert_file_contains "$f" "AZURE_CLIENT_SECRET"
assert_eq "$(stat -f '%Lp' "$f" 2>/dev/null || stat -c '%a' "$f")" "600"
teardown_test

setup_test "fails when the management group grant fails"
az_state APP_ID "app-42"; az_state SP_OID "sp-1"; az_state TENANT_ID "t-1"
export AZ_FAIL_MATCH="role assignment create.*Owner"
cd "$TEST_TMP"
if bash "$S" --resource-group rg --storage-account sa --container focus >/dev/null 2>"$TEST_TMP/err"; then
  fail "expected non-zero exit"
fi
assert_file_contains "$TEST_TMP/err" "management group"
unset AZ_FAIL_MATCH
teardown_test

finish_tests
```

- [ ] **Step 2: Run to verify they fail**

Run: `bash tests/test-create-kion-app.sh`
Expected: FAIL — script does not exist.

- [ ] **Step 3: Implement `scripts/create-kion-app.sh`**

Copy `create-customer-kion-app.sh` from the converter repo and apply these changes:
- Source `lib/common.sh` and call `resolve_cloud`; use `$GRAPH_ENDPOINT` instead of resolving it inline.
- Rename the credential file to `./kion-app-${APP_ID}-credential.env`.
- Drop every mention of the shared partner app from the header comment; this repo has no partner app.
- Print `APP_ID=$APP_ID` and `TENANT_DOMAIN=$TENANT_DOMAIN` on stdout (progress stays on stderr) so the caller can consume them.
- Keep unchanged: `--sign-in-audience AzureADMyOrg`, `credential reset --append`, the read-modify-write of redirect URIs, Graph permissions resolved by name then admin-consented, Owner on the management group as a **fatal** failure, Storage Blob Data Reader on the container, and `chmod 600` on the credential file.

- [ ] **Step 4: Run to verify they pass**

Run: `bash tests/test-create-kion-app.sh`
Expected: PASS — `5 run, 0 failed`.

- [ ] **Step 5: Commit**

```bash
chmod +x scripts/create-kion-app.sh
git add scripts/create-kion-app.sh tests/test-create-kion-app.sh
git commit -m "feat: create the app registration Kion authenticates as"
```

---

## Task 5: `kion-create-billing-source.sh`

**Files:**
- Create: `scripts/kion-create-billing-source.sh`, `tests/test-kion-billing-source.sh`

**Interfaces:**
- Consumes: `kion_account_type`, `cfg_get`, `log_*`
- Produces: script accepting `--tenant-file FILE --domain D --app-id A --client-secret S --endpoint E --container C --prefix P [--name N] [--dry-run]`; POSTs to Kion and writes `KION_PAYER_ID` back into the tenant file

- [ ] **Step 1: Write the failing tests**

`tests/test-kion-billing-source.sh`:
```bash
#!/bin/bash
set -uo pipefail
. "$(dirname "$0")/lib/harness.sh"
S="$REPO_DIR/scripts/kion-create-billing-source.sh"

new_tenant_file() {
  printf 'TENANT_ID=t-1\nBILLING_MODEL=%s\nAZURE_CLOUD=%s\nKION_PAYER_ID=\n' "$1" "$2" > "$TEST_TMP/t.env"
}
run_bs() {
  KION_HOST=https://kion.example KION_API_KEY=k bash "$S" \
    --tenant-file "$TEST_TMP/t.env" --domain d.onmicrosoft.us --app-id a --client-secret s \
    --endpoint https://sa.blob.core.usgovcloudapi.net/ --container focus --prefix focus "$@"
}

setup_test "posts to kion and records the payer id"
new_tenant_file MCA AzureUSGovernment
export CURL_BODY='{"data":{"id":77}}' CURL_CODE=201
run_bs >/dev/null
assert_curl_called "/v1/payer/standalone"
assert_file_contains "$TEST_TMP/t.env" "KION_PAYER_ID=77"
teardown_test

setup_test "uses the MCA gov account type"
new_tenant_file MCA AzureUSGovernment
run_bs >/dev/null
assert_curl_called '"account_type_id":18'
teardown_test

setup_test "uses the MCA commercial account type"
new_tenant_file MCA AzureCloud
run_bs >/dev/null
assert_curl_called '"account_type_id":16'
teardown_test

setup_test "skips when the tenant already has a payer id"
printf 'TENANT_ID=t-1\nBILLING_MODEL=MCA\nAZURE_CLOUD=AzureCloud\nKION_PAYER_ID=42\n' > "$TEST_TMP/t.env"
run_bs >/dev/null
[ -s "$TEST_TMP/curl.log" ] && fail "should not have called kion"
teardown_test

setup_test "dry run posts nothing"
new_tenant_file MCA AzureCloud
run_bs --dry-run >/dev/null
[ -s "$TEST_TMP/curl.log" ] && fail "dry run must not call kion"
teardown_test

setup_test "non-2xx is a failure"
new_tenant_file MCA AzureCloud
export CURL_CODE=403 CURL_BODY='{"message":"denied"}'
if run_bs >/dev/null 2>"$TEST_TMP/err"; then fail "expected non-zero exit"; fi
teardown_test

finish_tests
```

- [ ] **Step 2: Run to verify they fail**

Run: `bash tests/test-kion-billing-source.sh`
Expected: FAIL — script does not exist.

- [ ] **Step 3: Implement `scripts/kion-create-billing-source.sh`**

```bash
#!/bin/bash
#
# kion-create-billing-source.sh — register the Kion billing source that reads a
# tenant's FOCUS exports from blob storage.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

TENANT_FILE=""; DOMAIN=""; APP_ID=""; CLIENT_SECRET=""
ENDPOINT=""; CONTAINER=""; PREFIX=""; NAME=""; DRY_RUN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --tenant-file)   TENANT_FILE="$2"; shift 2 ;;
    --domain)        DOMAIN="$2"; shift 2 ;;
    --app-id)        APP_ID="$2"; shift 2 ;;
    --client-secret) CLIENT_SECRET="$2"; shift 2 ;;
    --endpoint)      ENDPOINT="$2"; shift 2 ;;
    --container)     CONTAINER="$2"; shift 2 ;;
    --prefix)        PREFIX="$2"; shift 2 ;;
    --name)          NAME="$2"; shift 2 ;;
    --dry-run)       DRY_RUN=1; shift ;;
    *) log_err "unknown argument: $1"; exit 2 ;;
  esac
done
[ -n "$TENANT_FILE" ] && [ -n "$DOMAIN" ] && [ -n "$APP_ID" ] || {
  log_err "--tenant-file, --domain and --app-id are required"; exit 2; }

KION_HOST="${KION_HOST:-}"; KION_API_KEY="${KION_API_KEY:-}"
KION_API_BASE="${KION_API_BASE:-/api}"
[ -n "$KION_HOST" ] && [ -n "$KION_API_KEY" ] || { log_err "KION_HOST and KION_API_KEY must be set"; exit 2; }

EXISTING="$(cfg_get "$TENANT_FILE" KION_PAYER_ID)"
if [ -n "$EXISTING" ]; then
  log_info "billing source already exists (payer $EXISTING); leaving it alone"
  exit 0
fi

MODEL="$(cfg_get "$TENANT_FILE" BILLING_MODEL)"; MODEL="${MODEL:-${BILLING_MODEL:-MCA}}"
CLOUD="$(cfg_get "$TENANT_FILE" AZURE_CLOUD)";   CLOUD="${CLOUD:-${AZURE_CLOUD:-AzureCloud}}"
ACCOUNT_TYPE_ID="$(kion_account_type "$MODEL" "$CLOUD")"
NAME="${NAME:-Azure $MODEL ($DOMAIN)}"

body="$(jq -nc \
  --argjson type "$ACCOUNT_TYPE_ID" --arg name "$NAME" --arg domain "$DOMAIN" \
  --arg app "$APP_ID" --arg secret "$CLIENT_SECRET" \
  --arg ep "$ENDPOINT" --arg cont "$CONTAINER" --arg prefix "$PREFIX" \
  '{account_type_id:$type, name:$name, domain:$domain,
    app_id:$app, client_secret:$secret,
    use_focus_reports:true,
    focus_storage_primary_endpoint:$ep,
    focus_storage_container:$cont,
    focus_storage_prefix:$prefix}')"

url="${KION_HOST%/}${KION_API_BASE%/}/v1/payer/standalone?createReport=false"
if [ "$DRY_RUN" -eq 1 ]; then
  log_info "[dry-run] would POST to $url"
  printf '%s\n' "$body" | jq 'del(.client_secret)'
  exit 0
fi

log_info "creating Kion billing source '$NAME' (account type $ACCOUNT_TYPE_ID)"
response="$(curl -sS -w '\n%{http_code}' -X POST \
  -H "Authorization: Bearer $KION_API_KEY" -H "Content-Type: application/json" \
  -d "$body" "$url")"
http_code="$(echo "$response" | tail -n1)"
http_body="$(echo "$response" | sed '$d')"
case "$http_code" in
  2*) : ;;
  *) log_err "Kion returned HTTP $http_code: $http_body"; exit 1 ;;
esac

payer_id="$(printf '%s' "$http_body" | jq -r '.data.id // empty' 2>/dev/null || true)"
if [ -n "$payer_id" ]; then
  if grep -qE '^[[:space:]]*KION_PAYER_ID=' "$TENANT_FILE"; then
    tmp="${TENANT_FILE}.tmp.$$"
    sed "s|^[[:space:]]*KION_PAYER_ID=.*|KION_PAYER_ID=${payer_id}|" "$TENANT_FILE" > "$tmp" \
      && cat "$tmp" > "$TENANT_FILE" && rm -f "$tmp"
  else
    printf 'KION_PAYER_ID=%s\n' "$payer_id" >> "$TENANT_FILE"
  fi
  log_info "recorded KION_PAYER_ID=$payer_id in $TENANT_FILE"
fi
```

- [ ] **Step 4: Run to verify they pass**

Run: `bash tests/test-kion-billing-source.sh`
Expected: PASS — `6 run, 0 failed`.

- [ ] **Step 5: Commit**

```bash
chmod +x scripts/kion-create-billing-source.sh
git add scripts/kion-create-billing-source.sh tests/test-kion-billing-source.sh
git commit -m "feat: register the Kion billing source and record the payer id"
```

---

## Task 6: `onboard-tenant.sh`

**Files:**
- Create: `scripts/onboard-tenant.sh`, `tests/test-onboard-tenant.sh`

**Interfaces:**
- Consumes: every script from Tasks 2-5, plus `cfg_get`, `resolve_cloud`, `log_*`
- Produces: script accepting `--tenant-file FILE [--skip-login]`; exits non-zero on any step failure

- [ ] **Step 1: Write the failing tests**

`tests/test-onboard-tenant.sh`:
```bash
#!/bin/bash
set -uo pipefail
. "$(dirname "$0")/lib/harness.sh"
S="$REPO_DIR/scripts/onboard-tenant.sh"

write_tenant() {
  cat > "$TEST_TMP/t.env" <<EOF
TENANT_ID=t-1
AZURE_CLOUD=AzureUSGovernment
BILLING_MODEL=MCA
RESOURCE_GROUP=rg
STORAGE_ACCOUNT=sa
CONTAINER=focus
LOCATION=usgovvirginia
KION_PAYER_ID=
EOF
}

setup_test "runs storage, exports, app and billing source in order"
write_tenant
az_state TENANT_ID t-1; az_state RG_EXISTS 1; az_state SA_EXISTS 1
az_state BLOB_ENDPOINT "https://sa.blob.core.usgovcloudapi.net/"
az_state SUBSCRIPTIONS "sub-a"; az_state APP_ID "app-1"; az_state SP_OID "sp-1"
cd "$TEST_TMP"
KION_HOST=https://k KION_API_KEY=k bash "$S" --tenant-file "$TEST_TMP/t.env" --skip-login >/dev/null
assert_az_called "storage container create"
assert_az_called "rest --method put"
assert_az_called "ad app"
assert_curl_called "/v1/payer/standalone"
teardown_test

setup_test "stops before the billing source when exports fail"
write_tenant
az_state TENANT_ID t-1; az_state RG_EXISTS 1; az_state SA_EXISTS 1
az_state BLOB_ENDPOINT "https://sa.blob.core.usgovcloudapi.net/"
az_state SUBSCRIPTIONS "sub-a"
export AZ_FAIL_MATCH="rest --method put"
cd "$TEST_TMP"
if KION_HOST=https://k KION_API_KEY=k bash "$S" --tenant-file "$TEST_TMP/t.env" --skip-login >/dev/null 2>&1; then
  fail "expected non-zero exit"
fi
[ -s "$TEST_TMP/curl.log" ] && fail "must not create a billing source without exports"
unset AZ_FAIL_MATCH
teardown_test

setup_test "refuses to run against the wrong tenant"
write_tenant
az_state TENANT_ID "someone-else"
cd "$TEST_TMP"
if KION_HOST=https://k KION_API_KEY=k bash "$S" --tenant-file "$TEST_TMP/t.env" --skip-login >/dev/null 2>"$TEST_TMP/err"; then
  fail "expected non-zero exit"
fi
assert_file_contains "$TEST_TMP/err" "tenant"
teardown_test

finish_tests
```

- [ ] **Step 2: Run to verify they fail**

Run: `bash tests/test-onboard-tenant.sh`
Expected: FAIL — script does not exist.

- [ ] **Step 3: Implement `scripts/onboard-tenant.sh`**

```bash
#!/bin/bash
#
# onboard-tenant.sh — stand up one tenant end to end. Every step is
# independently re-runnable, so a partial failure is resumed by running again.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/common.sh"

TENANT_FILE=""; SKIP_LOGIN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --tenant-file) TENANT_FILE="$2"; shift 2 ;;
    --skip-login)  SKIP_LOGIN=1; shift ;;
    *) log_err "unknown argument: $1"; exit 2 ;;
  esac
done
[ -f "$TENANT_FILE" ] || { log_err "tenant file not found: $TENANT_FILE"; exit 2; }

TENANT_ID="$(cfg_get "$TENANT_FILE" TENANT_ID)"
[ -n "$TENANT_ID" ] || { log_err "$TENANT_FILE has no TENANT_ID"; exit 2; }
AZURE_CLOUD="$(cfg_get "$TENANT_FILE" AZURE_CLOUD)"; AZURE_CLOUD="${AZURE_CLOUD:-${AZURE_CLOUD_DEFAULT:-AzureCloud}}"
export AZURE_CLOUD
RG="$(cfg_get "$TENANT_FILE" RESOURCE_GROUP)"
STORAGE="$(cfg_get "$TENANT_FILE" STORAGE_ACCOUNT)"
CONTAINER="$(cfg_get "$TENANT_FILE" CONTAINER)"
LOCATION="$(cfg_get "$TENANT_FILE" LOCATION)"
PREFIX="$(cfg_get "$TENANT_FILE" EXPORT_PREFIX)"; PREFIX="${PREFIX:-${EXPORT_PREFIX:-focus}}"
SCOPE="$(cfg_get "$TENANT_FILE" EXPORT_SCOPE)"; SCOPE="${SCOPE:-subscription}"
BILLING_SCOPE_ID="$(cfg_get "$TENANT_FILE" BILLING_SCOPE_ID)"
SUBSCRIPTIONS="$(cfg_get "$TENANT_FILE" SUBSCRIPTIONS)"
MG="$(cfg_get "$TENANT_FILE" MANAGEMENT_GROUP)"

# 1) log in to this tenant
if [ "$SKIP_LOGIN" -eq 0 ]; then
  current="$(az account show --query tenantId -o tsv 2>/dev/null || echo "")"
  if [ "$current" != "$TENANT_ID" ]; then
    log_info "signing in to tenant $TENANT_ID"
    az login --tenant "$TENANT_ID" --only-show-errors >/dev/null
  fi
fi
current="$(az account show --query tenantId -o tsv 2>/dev/null || echo "")"
[ "$current" = "$TENANT_ID" ] || { log_err "active tenant '$current' is not the configured tenant '$TENANT_ID'"; exit 1; }

# 2) storage
BLOB_ENDPOINT="$("$HERE/ensure-storage.sh" --resource-group "$RG" --storage-account "$STORAGE" \
  --container "$CONTAINER" ${LOCATION:+--location "$LOCATION"})"
STORAGE_ID="$(az storage account show --name "$STORAGE" --resource-group "$RG" --query id -o tsv)"

# 3) exports — before the billing source, so Kion is never pointed at an
#    empty container with nothing feeding it
"$HERE/create-focus-exports.sh" \
  --storage-account-id "$STORAGE_ID" --container "$CONTAINER" --prefix "$PREFIX" \
  --scope "$SCOPE" ${BILLING_SCOPE_ID:+--billing-scope-id "$BILLING_SCOPE_ID"} \
  ${SUBSCRIPTIONS:+--subscriptions "$SUBSCRIPTIONS"} \
  ${FOCUS_VERSION:+--focus-version "$FOCUS_VERSION"} \
  ${EXPORT_RECURRENCE:+--recurrence "$EXPORT_RECURRENCE"} \
  ${EXPORT_TIMEFRAME:+--timeframe "$EXPORT_TIMEFRAME"} >/dev/null

# 4) the app Kion authenticates as
app_out="$("$HERE/create-kion-app.sh" --resource-group "$RG" --storage-account "$STORAGE" \
  --container "$CONTAINER" ${MG:+--management-group "$MG"} ${KION_HOST:+--kion-url "$KION_HOST"})"
APP_ID="$(printf '%s' "$app_out" | sed -n 's/^APP_ID=//p')"
TENANT_DOMAIN="$(printf '%s' "$app_out" | sed -n 's/^TENANT_DOMAIN=//p')"
CLIENT_SECRET="$(cfg_get "./kion-app-${APP_ID}-credential.env" AZURE_CLIENT_SECRET)"

# 5) the Kion billing source
"$HERE/kion-create-billing-source.sh" --tenant-file "$TENANT_FILE" \
  --domain "$TENANT_DOMAIN" --app-id "$APP_ID" --client-secret "$CLIENT_SECRET" \
  --endpoint "$BLOB_ENDPOINT" --container "$CONTAINER" --prefix "$PREFIX"

log_info "tenant $TENANT_ID onboarded"
```

- [ ] **Step 4: Run to verify they pass**

Run: `bash tests/test-onboard-tenant.sh`
Expected: PASS — `3 run, 0 failed`.

- [ ] **Step 5: Commit**

```bash
chmod +x scripts/onboard-tenant.sh
git add scripts/onboard-tenant.sh tests/test-onboard-tenant.sh
git commit -m "feat: onboard one tenant end to end"
```

---

## Task 7: `onboard-all.sh`, Makefile, docs

**Files:**
- Create: `scripts/onboard-all.sh`, `Makefile`, `.env.example`, `tenants/example.env.example`, `README.md`, `tests/test-onboard-all.sh`

**Interfaces:**
- Consumes: `scripts/onboard-tenant.sh`, `summary_*` from `lib/common.sh`
- Produces: `make onboard TENANT=<name>`, `make onboard-all`, `make test`

- [ ] **Step 1: Write the failing tests**

`tests/test-onboard-all.sh`:
```bash
#!/bin/bash
set -uo pipefail
. "$(dirname "$0")/lib/harness.sh"
S="$REPO_DIR/scripts/onboard-all.sh"

make_tenants() {
  mkdir -p "$TEST_TMP/tenants"
  for n in "$@"; do
    printf 'TENANT_ID=%s\nRESOURCE_GROUP=rg\nSTORAGE_ACCOUNT=sa\nCONTAINER=focus\nKION_PAYER_ID=\n' "$n" \
      > "$TEST_TMP/tenants/$n.env"
  done
}

setup_test "one failing tenant does not stop the others"
make_tenants alpha beta
# a stub onboard-tenant that fails only for alpha
mkdir -p "$TEST_TMP/bin"
cat > "$TEST_TMP/bin/onboard-tenant.sh" <<'EOF'
#!/bin/bash
case "$*" in *alpha*) echo "boom" >&2; exit 1 ;; *) exit 0 ;; esac
EOF
chmod +x "$TEST_TMP/bin/onboard-tenant.sh"
out="$(ONBOARD_TENANT_BIN="$TEST_TMP/bin/onboard-tenant.sh" bash "$S" --dir "$TEST_TMP/tenants" 2>&1)" || rc=$?
case "$out" in *alpha*failed*) : ;; *) fail "alpha not reported failed" ;; esac
case "$out" in *beta*ok*) : ;; *) fail "beta not reported ok" ;; esac
teardown_test

setup_test "exits non-zero when any tenant failed"
make_tenants alpha
mkdir -p "$TEST_TMP/bin"
printf '#!/bin/bash\nexit 1\n' > "$TEST_TMP/bin/onboard-tenant.sh"
chmod +x "$TEST_TMP/bin/onboard-tenant.sh"
if ONBOARD_TENANT_BIN="$TEST_TMP/bin/onboard-tenant.sh" bash "$S" --dir "$TEST_TMP/tenants" >/dev/null 2>&1; then
  fail "expected non-zero exit"
fi
teardown_test

setup_test "exits zero when all tenants succeed"
make_tenants alpha beta
mkdir -p "$TEST_TMP/bin"
printf '#!/bin/bash\nexit 0\n' > "$TEST_TMP/bin/onboard-tenant.sh"
chmod +x "$TEST_TMP/bin/onboard-tenant.sh"
ONBOARD_TENANT_BIN="$TEST_TMP/bin/onboard-tenant.sh" bash "$S" --dir "$TEST_TMP/tenants" >/dev/null 2>&1 \
  || fail "expected zero exit"
teardown_test

finish_tests
```

- [ ] **Step 2: Run to verify they fail**

Run: `bash tests/test-onboard-all.sh`
Expected: FAIL — script does not exist.

- [ ] **Step 3: Implement `scripts/onboard-all.sh`**

```bash
#!/bin/bash
#
# onboard-all.sh — run every tenant in tenants/, continuing past failures, and
# print a summary. Exits non-zero if any tenant failed.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/common.sh"

DIR="$HERE/../tenants"
while [ $# -gt 0 ]; do
  case "$1" in
    --dir) DIR="$2"; shift 2 ;;
    *) log_err "unknown argument: $1"; exit 2 ;;
  esac
done
ONBOARD_TENANT_BIN="${ONBOARD_TENANT_BIN:-$HERE/onboard-tenant.sh}"

summary_reset
found=0
for f in "$DIR"/*.env; do
  [ -f "$f" ] || continue
  case "$f" in *.example) continue ;; esac
  found=1
  name="$(basename "$f" .env)"
  log_info "=== $name ==="
  # Each tenant in its own subshell: one failure must not abort the loop or
  # leak variables into the next tenant.
  if ( "$ONBOARD_TENANT_BIN" --tenant-file "$f" ); then
    summary_add "$name" ok "onboarded"
  else
    summary_add "$name" failed "see output above"
  fi
done

[ "$found" -eq 1 ] || { log_err "no tenant files in $DIR"; exit 2; }
summary_print
exit "$(summary_exit_code)"
```

- [ ] **Step 4: Create `Makefile`**

```makefile
.PHONY: help onboard onboard-all exports kion-source test

TENANTS_DIR ?= tenants
TENANT ?=
TENANT_FILE ?= $(if $(strip $(TENANT)),$(TENANTS_DIR)/$(TENANT).env,)

-include .env
export

help: ## Show available targets
	@grep -hE '^[a-z-]+:.*##' $(MAKEFILE_LIST) | sed 's/:.*##/\t/' | sort

onboard: ## Onboard one tenant: make onboard TENANT=<name>
	@[ -n "$(strip $(TENANT))" ] || { echo "ERROR: TENANT=<name> is required"; exit 2; }
	scripts/onboard-tenant.sh --tenant-file "$(TENANT_FILE)"

onboard-all: ## Onboard every tenant in tenants/, continuing past failures
	scripts/onboard-all.sh --dir "$(TENANTS_DIR)"

test: ## Run the test suite
	bash tests/run-tests.sh
```

- [ ] **Step 5: Create `.env.example`**

```sh
# Kion connection. One Kion serves every tenant.
KION_HOST=
KION_API_KEY=
KION_API_BASE=/api

# Defaults, overridable per tenant. Gov and Commercial tenants are expected to
# be onboarded from the same checkout, so both of these are per-tenant settings
# with a default here.
AZURE_CLOUD=AzureCloud
BILLING_MODEL=MCA

# FOCUS export settings. FocusCost only: the FOCUS dataset already carries both
# actual (BilledCost) and amortized (EffectiveCost) costs, and Kion cannot read
# the ActualCost/AmortizedCost dataset types.
FOCUS_VERSION=1.0
EXPORT_RECURRENCE=Daily
EXPORT_TIMEFRAME=MonthToDate
EXPORT_PREFIX=focus
```

- [ ] **Step 6: Create `tenants/example.env.example`**

```sh
# One file per tenant. Copy to tenants/<name>.env and fill in.
# Run it with: make onboard TENANT=<name>

TENANT_ID=
AZURE_CLOUD=                 # AzureCloud or AzureUSGovernment; overrides .env
BILLING_MODEL=               # MCA or CSP; overrides .env

# Storage for this tenant's FOCUS exports. Created if missing. The storage
# account name must be globally unique, 3-24 chars, lowercase letters and digits.
RESOURCE_GROUP=
STORAGE_ACCOUNT=
CONTAINER=
LOCATION=

# subscription (default) creates one export per subscription. MCA can instead
# use billingProfile or billingAccount for a single export covering everything,
# which then needs BILLING_SCOPE_ID. Management group scope is not supported by
# Azure for FOCUS exports.
EXPORT_SCOPE=subscription
BILLING_SCOPE_ID=
SUBSCRIPTIONS=               # optional allowlist, space separated; empty means all

MANAGEMENT_GROUP=            # Owner is granted here; empty means the tenant root group

# Written back automatically once the billing source is created. Leave empty.
KION_PAYER_ID=
```

- [ ] **Step 7: Create `README.md`**

```markdown
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

    az login                                   # to the tenant being onboarded
    make onboard TENANT=<name>

Or every tenant in `tenants/`, continuing past failures and printing a summary:

    make onboard-all

Each run logs in to the tenant, creates the resource group / storage account /
container if missing, creates one FOCUS export per subscription (or one at a
billing scope for MCA), creates the Kion app with the permissions Kion needs,
and registers the billing source — recording the payer id back into the
tenant's file so a later run leaves it alone.

Every step is idempotent, so re-running after a failure resumes rather than
duplicating.

## Requirements in each tenant

- **Application Administrator** to create the app and grant admin consent
- **Contributor** or Owner to create the resource group and storage account
- **Owner** or **User Access Administrator** on the management group. This is
  the one that usually blocks a first run: subscription Owner does not carry up
  to the management group. Either point `MANAGEMENT_GROUP` at a group you own,
  or have a Global Admin enable "Access management for Azure resources" and
  sign in again.

## Tests

    make test

Tests stub `az` and `curl` on `PATH` and assert on the calls made. Nothing
touches Azure or Kion.
```

- [ ] **Step 8: Run the full suite**

Run: `make test`
Expected: PASS — every test file reports `0 failed`.

- [ ] **Step 9: Verify every script parses and is executable**

```bash
for f in scripts/*.sh scripts/lib/*.sh; do bash -n "$f" || exit 1; done
chmod +x scripts/*.sh
command -v shellcheck >/dev/null && shellcheck -S warning scripts/*.sh || true
```

- [ ] **Step 10: Commit**

```bash
git add scripts/onboard-all.sh Makefile .env.example tenants/example.env.example README.md tests/test-onboard-all.sh
git commit -m "feat: tenant loop with summary, make targets and docs"
```

---

## Task 8: Verify against a real tenant

The spec lists four things that cannot be settled with stubs. Each needs a real
run before this tool is trusted with a customer.

**Files:**
- Modify: `README.md` (record the confirmed values)

- [ ] **Step 1: Confirm the export api-version on both clouds**

Run `make onboard TENANT=<a test tenant>` on Commercial and on Gov. If `az rest`
rejects `2023-08-01`, retry with `--api-version 2025-03-01` and set
`EXPORT_API_VERSION` in `.env` accordingly.

- [ ] **Step 2: Confirm Kion reads the nested prefixes**

The layout writes to `<container>/<prefix>/<scope-id>/...`, so Kion's FOCUS
ingestion must recurse below the configured prefix. After the first export
lands, confirm spend appears on the billing source. If it does not, flatten the
layout to one prefix per tenant and create one export per subscription writing
into the same folder.

- [ ] **Step 3: Decide whether a "Run now" is needed**

Exports can take up to a day to produce their first file. If that is too slow
for onboarding, add a `Run now` POST to `create-focus-exports.sh` after the PUT.

- [ ] **Step 4: Confirm the MCA payer payload**

The billing source body was modelled on the CSP shape. Create one MCA billing
source and confirm Kion accepts it and both credential tests pass. If MCA needs
different fields, adjust `kion-create-billing-source.sh` and add a test.

- [ ] **Step 5: Record findings and commit**

```bash
git add README.md .env.example
git commit -m "docs: record verified api-version, prefix behaviour and MCA payload"
```

---

## Self-Review

**Spec coverage:** Purpose → Tasks 6-7. Non-goals (no image, no cross-tenant write) → honoured; nothing in the plan creates a partner app or consents a foreign identity. Environments/cloud matrix → Task 1 `resolve_cloud` + `kion_account_type`, tested for Gov and Commercial. Flow steps 1-7 → Task 6 in the same order. Repo layout → Tasks 1-7 create every listed file. Configuration → Task 7 `.env.example` and tenant template, with per-tenant overrides read via `cfg_get`. Export payload → Task 3. Error handling/summary → Task 7. Testing → harness in Task 1, cases in every task. "To verify during implementation" → Task 8.

**Placeholder scan:** No TBDs. Task 4 describes edits to a named existing file rather than restating 200 lines; the file path and every behaviour to preserve or change is listed explicitly.

**Type consistency:** `cfg_get FILE KEY`, `resolve_cloud`, `kion_account_type MODEL CLOUD`, `summary_add/print/exit_code/reset` are defined in Task 1 and used with those exact signatures in Tasks 2-7. `create-kion-app.sh` prints `APP_ID=` / `TENANT_DOMAIN=` (Task 4) and Task 6 parses exactly those. The credential file is `kion-app-<appId>-credential.env` in both Task 4 and Task 6.
