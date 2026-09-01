#!/bin/bash
set -uo pipefail
. "$(dirname "$0")/lib/harness.sh"
S="$REPO_DIR/scripts/onboard-tenant.sh"

# Bare GUID-shaped subscription id fixtures, matching the shape
# create-focus-exports.sh's subscription-id guard now requires.
SUB_A="aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
SUB_B="bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"

# This file runs without `set -e`, so a success-path invocation's exit code has
# to be captured and asserted explicitly. It was not, and the curl stub's
# default body was invalid JSON, so every "success path" test here was in fact
# exercising a run that exited 1 with the payer id never written back -- and
# reporting ok. Capture the code directly; never `|| true`.
assert_rc_zero() { # RC LABEL
  [ "$1" -eq 0 ] || fail "$2 exited $1, expected 0"
}

write_tenant() {
  cat > "$TEST_TMP/t.env" <<EOF
TENANT_ID=t-1
AZURE_CLOUD=AzureUSGovernment
BILLING_MODEL=MCA
RESOURCE_GROUP=rg
STORAGE_ACCOUNT=sa
CONTAINER=focus
LOCATION=usgovvirginia
EXPORT_SCOPE=subscription
KION_PAYER_ID=
EOF
}

setup_test "runs storage, exports, app and billing source in order"
write_tenant
az_state TENANT_ID t-1; az_state ENVIRONMENT_NAME AzureUSGovernment; az_state RG_EXISTS 1; az_state SA_EXISTS 1
az_state BLOB_ENDPOINT "https://sa.blob.core.usgovcloudapi.net/"
az_state SUBSCRIPTIONS "$SUB_A"; az_state APP_ID "app-1"; az_state SP_OID "sp-1"
cd "$TEST_TMP" || exit 1
KION_HOST=https://k KION_API_KEY=k bash "$S" --tenant-file "$TEST_TMP/t.env" --skip-login >/dev/null
rc=$?
assert_rc_zero "$rc" "onboard-tenant.sh happy path"
assert_az_called "storage container create"
assert_az_called "rest --method put"
assert_az_called "ad app"
assert_curl_called "/v1/payer/standalone"
# The spec's first Testing case: the payer id Kion returned lands in the
# tenant file. The curl stub's default body carries id 1.
assert_file_contains "$TEST_TMP/t.env" "^KION_PAYER_ID=1$"
teardown_test

setup_test "reports each completed step on stdout for the run summary"
write_tenant
az_state TENANT_ID t-1; az_state ENVIRONMENT_NAME AzureUSGovernment; az_state RG_EXISTS 1; az_state SA_EXISTS 1
az_state BLOB_ENDPOINT "https://sa.blob.core.usgovcloudapi.net/"
az_state SUBSCRIPTIONS "$SUB_A"; az_state APP_ID "app-1"; az_state SP_OID "sp-1"
cd "$TEST_TMP" || exit 1
out="$(KION_HOST=https://k KION_API_KEY=k bash "$S" --tenant-file "$TEST_TMP/t.env" --skip-login 2>/dev/null)"
rc=$?
assert_rc_zero "$rc" "onboard-tenant.sh happy path"
for step in storage exports app billing-source; do
  case "$out" in *"STEP=$step:ok"*) : ;; *) fail "no STEP=$step:ok line on stdout: $out" ;; esac
done
teardown_test

setup_test "an already-onboarded tenant reports billing-source warn, not ok, and still exits 0"
write_tenant
# Pre-set payer id: kion-create-billing-source.sh will refuse to touch Kion and
# deliberately leaves the prefix alone, so this run does NOT finish the job.
printf 'KION_PAYER_ID=42\n' >> "$TEST_TMP/t.env"
az_state TENANT_ID t-1; az_state ENVIRONMENT_NAME AzureUSGovernment; az_state RG_EXISTS 1; az_state SA_EXISTS 1
az_state BLOB_ENDPOINT "https://sa.blob.core.usgovcloudapi.net/"
az_state SUBSCRIPTIONS "$SUB_A"; az_state APP_ID "app-1"; az_state SP_OID "sp-1"
cd "$TEST_TMP" || exit 1
out="$(KION_HOST=https://k KION_API_KEY=k bash "$S" --tenant-file "$TEST_TMP/t.env" --skip-login 2>"$TEST_TMP/err")"
rc=$?
assert_rc_zero "$rc" "re-onboard of an already-onboarded tenant"
case "$out" in *"STEP=billing-source:warn"*) : ;; *) fail "billing source not reported as warn: $out" ;; esac
case "$out" in *"STEP=billing-source:ok"*) fail "an unfinished billing-source step was reported ok" ;; esac
case "$out" in *STEP_DETAIL=*42*) : ;; *) fail "detail line does not name the existing payer id: $out" ;; esac
[ -s "$TEST_TMP/curl.log" ] && fail "must not create a second billing source"
# A fresh client secret was minted and cannot be delivered to Kion by this run;
# the operator has to be told, not left to discover it.
assert_file_contains "$TEST_TMP/err" "new client secret was generated"
teardown_test

setup_test "stops before the billing source when exports fail"
write_tenant
az_state TENANT_ID t-1; az_state ENVIRONMENT_NAME AzureUSGovernment; az_state RG_EXISTS 1; az_state SA_EXISTS 1
az_state BLOB_ENDPOINT "https://sa.blob.core.usgovcloudapi.net/"
az_state SUBSCRIPTIONS "$SUB_A"
export AZ_FAIL_MATCH="rest --method put"
cd "$TEST_TMP" || exit 1
if KION_HOST=https://k KION_API_KEY=k bash "$S" --tenant-file "$TEST_TMP/t.env" --skip-login >/dev/null 2>&1; then
  fail "expected non-zero exit"
fi
[ -s "$TEST_TMP/curl.log" ] && fail "must not create a billing source without exports"
unset AZ_FAIL_MATCH
teardown_test

setup_test "refuses to run against the wrong tenant"
write_tenant
az_state TENANT_ID "someone-else"
cd "$TEST_TMP" || exit 1
if KION_HOST=https://k KION_API_KEY=k bash "$S" --tenant-file "$TEST_TMP/t.env" --skip-login >/dev/null 2>"$TEST_TMP/err"; then
  fail "expected non-zero exit"
fi
assert_file_contains "$TEST_TMP/err" "tenant"
teardown_test

# "Which cloud" has two independent sources of truth: the CLI's active cloud
# (which resolve_cloud reads endpoints from) and AZURE_CLOUD (which picks the
# Kion account type id). Nothing in this tool runs `az cloud set`, so they can
# disagree, and a disagreement produces the right data under the wrong Kion
# account type with no error anywhere.
setup_test "refuses to run when the CLI's active cloud is not the configured cloud"
write_tenant  # AZURE_CLOUD=AzureUSGovernment
az_state TENANT_ID t-1; az_state ENVIRONMENT_NAME AzureCloud; az_state RG_EXISTS 1; az_state SA_EXISTS 1
az_state BLOB_ENDPOINT "https://sa.blob.core.usgovcloudapi.net/"
az_state SUBSCRIPTIONS "$SUB_A"; az_state APP_ID "app-1"; az_state SP_OID "sp-1"
cd "$TEST_TMP" || exit 1
# --skip-login deliberately: skipping the login is precisely when the operator's
# own `az cloud set` is what is in force, so the check has to hold here too.
if KION_HOST=https://k KION_API_KEY=k bash "$S" --tenant-file "$TEST_TMP/t.env" --skip-login \
   >/dev/null 2>"$TEST_TMP/err"; then
  fail "expected non-zero exit"
fi
# The error has to name the active cloud and the configured one -- neither
# alone tells an operator which end to change -- and give the remedy.
assert_file_contains "$TEST_TMP/err" "AzureCloud.*AzureUSGovernment"
assert_file_contains "$TEST_TMP/err" "az cloud set --name AzureUSGovernment"
# ...and it must stop before anything is created, not be discovered afterwards.
assert_az_not_called "storage container create"
assert_az_not_called "rest --method put"
assert_az_not_called "ad app"
[ -s "$TEST_TMP/curl.log" ] && fail "must not register a billing source from the wrong cloud"
teardown_test

setup_test "a Commercial tenant on a Commercial CLI passes the cloud check and gets the commercial account type"
cat > "$TEST_TMP/t.env" <<EOF
TENANT_ID=t-1
AZURE_CLOUD=AzureCloud
BILLING_MODEL=MCA
RESOURCE_GROUP=rg
STORAGE_ACCOUNT=sa
CONTAINER=focus
LOCATION=eastus
EXPORT_SCOPE=subscription
KION_PAYER_ID=
EOF
az_state TENANT_ID t-1; az_state ENVIRONMENT_NAME AzureCloud; az_state RG_EXISTS 1; az_state SA_EXISTS 1
az_state BLOB_ENDPOINT "https://sa.blob.core.windows.net/"
az_state SUBSCRIPTIONS "$SUB_A"; az_state APP_ID "app-1"; az_state SP_OID "sp-1"
cd "$TEST_TMP" || exit 1
KION_HOST=https://k KION_API_KEY=k bash "$S" --tenant-file "$TEST_TMP/t.env" --skip-login >/dev/null
rc=$?
assert_rc_zero "$rc" "commercial-on-commercial run"
# The guard compares two values, so it must pass a matching Commercial pair as
# readily as a matching Gov one; nothing here may hardcode a cloud. Asserting
# the account type as well ties the check to the thing it exists to protect.
assert_curl_stdin_contains '"account_type_id":16'
teardown_test

setup_test "tenant file with no AZURE_CLOUD falls back to the inherited environment, not Commercial"
cat > "$TEST_TMP/t.env" <<EOF
TENANT_ID=t-1
BILLING_MODEL=MCA
RESOURCE_GROUP=rg
STORAGE_ACCOUNT=sa
CONTAINER=focus
LOCATION=usgovvirginia
EXPORT_SCOPE=subscription
KION_PAYER_ID=
EOF
az_state TENANT_ID t-1; az_state ENVIRONMENT_NAME AzureUSGovernment; az_state RG_EXISTS 1; az_state SA_EXISTS 1
az_state BLOB_ENDPOINT "https://sa.blob.core.usgovcloudapi.net/"
az_state SUBSCRIPTIONS "$SUB_A"; az_state APP_ID "app-1"; az_state SP_OID "sp-1"
cd "$TEST_TMP" || exit 1
AZURE_CLOUD=AzureUSGovernment KION_HOST=https://k KION_API_KEY=k \
  bash "$S" --tenant-file "$TEST_TMP/t.env" --skip-login >/dev/null
rc=$?
assert_rc_zero "$rc" "inherited AZURE_CLOUD run"
# resolve_cloud falls back to the Gov literals when `az cloud show` returns
# nothing (as the stub does here), so a Gov-specific ARM endpoint reaching the
# FOCUS export's `az rest` call proves AZURE_CLOUD carried through as Gov
# rather than being reset to the AzureCloud default.
assert_az_called "usgovcloudapi.net"
teardown_test

setup_test "aborts before any curl call when create-kion-app.sh yields no APP_ID"
write_tenant
az_state TENANT_ID t-1; az_state ENVIRONMENT_NAME AzureUSGovernment; az_state RG_EXISTS 1; az_state SA_EXISTS 1
az_state BLOB_ENDPOINT "https://sa.blob.core.usgovcloudapi.net/"
az_state SUBSCRIPTIONS "$SUB_A"
# Exercise onboard-tenant.sh's own validation, not create-kion-app.sh's
# internals: run it against a copy of scripts/ with create-kion-app.sh
# replaced by a fake that succeeds but never prints an APP_ID= line.
mkdir -p "$TEST_TMP/scripts/lib"
cp "$REPO_DIR"/scripts/*.sh "$TEST_TMP/scripts/"
cp "$REPO_DIR"/scripts/lib/common.sh "$TEST_TMP/scripts/lib/"
cat > "$TEST_TMP/scripts/create-kion-app.sh" <<'EOF'
#!/bin/bash
echo "TENANT_DOMAIN=example.onmicrosoft.us"
echo "CREDENTIAL_FILE=/dev/null"
EOF
chmod +x "$TEST_TMP/scripts/create-kion-app.sh"
cd "$TEST_TMP" || exit 1
if KION_HOST=https://k KION_API_KEY=k \
  bash "$TEST_TMP/scripts/onboard-tenant.sh" --tenant-file "$TEST_TMP/t.env" --skip-login \
  >/dev/null 2>"$TEST_TMP/err"; then
  fail "expected non-zero exit"
fi
[ -s "$TEST_TMP/curl.log" ] && fail "must not register a billing source with a missing APP_ID"
assert_file_contains "$TEST_TMP/err" "APP_ID"
teardown_test

setup_test "EXPORT_API_VERSION: tenant file overrides the inherited .env default"
cat > "$TEST_TMP/t.env" <<EOF
TENANT_ID=t-1
AZURE_CLOUD=AzureUSGovernment
BILLING_MODEL=MCA
RESOURCE_GROUP=rg
STORAGE_ACCOUNT=sa
CONTAINER=focus
LOCATION=usgovvirginia
EXPORT_SCOPE=subscription
EXPORT_API_VERSION=2025-03-01
KION_PAYER_ID=
EOF
az_state TENANT_ID t-1; az_state ENVIRONMENT_NAME AzureUSGovernment; az_state RG_EXISTS 1; az_state SA_EXISTS 1
az_state BLOB_ENDPOINT "https://sa.blob.core.usgovcloudapi.net/"
az_state SUBSCRIPTIONS "$SUB_A"; az_state APP_ID "app-1"; az_state SP_OID "sp-1"
cd "$TEST_TMP" || exit 1
EXPORT_API_VERSION=2023-08-01 KION_HOST=https://k KION_API_KEY=k \
  bash "$S" --tenant-file "$TEST_TMP/t.env" --skip-login >/dev/null
rc=$?
assert_rc_zero "$rc" "EXPORT_API_VERSION override run"
assert_az_called "api-version=2025-03-01"
grep -q "api-version=2023-08-01" "$TEST_TMP/az.log" && fail "tenant file value did not win over the inherited .env default"
teardown_test

setup_test "EXPORT_API_VERSION: inherited .env default flows through when the tenant file omits it"
write_tenant
az_state TENANT_ID t-1; az_state ENVIRONMENT_NAME AzureUSGovernment; az_state RG_EXISTS 1; az_state SA_EXISTS 1
az_state BLOB_ENDPOINT "https://sa.blob.core.usgovcloudapi.net/"
az_state SUBSCRIPTIONS "$SUB_A"; az_state APP_ID "app-1"; az_state SP_OID "sp-1"
cd "$TEST_TMP" || exit 1
EXPORT_API_VERSION=9999-01-01 KION_HOST=https://k KION_API_KEY=k \
  bash "$S" --tenant-file "$TEST_TMP/t.env" --skip-login >/dev/null
rc=$?
assert_rc_zero "$rc" "inherited EXPORT_API_VERSION run"
assert_az_called "api-version=9999-01-01"
teardown_test

# The README promises per-tenant values override .env. FOCUS_VERSION,
# EXPORT_RECURRENCE and EXPORT_TIMEFRAME were read only from the environment,
# so a tenant file setting them was parsed by nobody and silently ignored.
setup_test "FOCUS_VERSION, EXPORT_RECURRENCE and EXPORT_TIMEFRAME: the tenant file wins over the inherited .env"
cat > "$TEST_TMP/t.env" <<EOF
TENANT_ID=t-1
AZURE_CLOUD=AzureUSGovernment
BILLING_MODEL=MCA
RESOURCE_GROUP=rg
STORAGE_ACCOUNT=sa
CONTAINER=focus
LOCATION=usgovvirginia
EXPORT_SCOPE=subscription
FOCUS_VERSION=1.2-preview
EXPORT_RECURRENCE=Weekly
EXPORT_TIMEFRAME=WeekToDate
KION_PAYER_ID=
EOF
az_state TENANT_ID t-1; az_state ENVIRONMENT_NAME AzureUSGovernment; az_state RG_EXISTS 1; az_state SA_EXISTS 1
az_state BLOB_ENDPOINT "https://sa.blob.core.usgovcloudapi.net/"
az_state SUBSCRIPTIONS "$SUB_A"; az_state APP_ID "app-1"; az_state SP_OID "sp-1"
cd "$TEST_TMP" || exit 1
FOCUS_VERSION=1.0 EXPORT_RECURRENCE=Daily EXPORT_TIMEFRAME=MonthToDate \
  KION_HOST=https://k KION_API_KEY=k \
  bash "$S" --tenant-file "$TEST_TMP/t.env" --skip-login >/dev/null
rc=$?
assert_rc_zero "$rc" "per-tenant export settings run"
assert_az_called "1.2-preview"
assert_az_called "Weekly"
assert_az_called "WeekToDate"
grep -q "MonthToDate" "$TEST_TMP/az.log" && fail "inherited EXPORT_TIMEFRAME leaked past the tenant file value"
grep -qE '"dataVersion":"1\.0"' "$TEST_TMP/az.log" && fail "inherited FOCUS_VERSION leaked past the tenant file value"
teardown_test

setup_test "FOCUS_VERSION, EXPORT_RECURRENCE and EXPORT_TIMEFRAME still inherit from .env when the tenant file omits them"
write_tenant
az_state TENANT_ID t-1; az_state ENVIRONMENT_NAME AzureUSGovernment; az_state RG_EXISTS 1; az_state SA_EXISTS 1
az_state BLOB_ENDPOINT "https://sa.blob.core.usgovcloudapi.net/"
az_state SUBSCRIPTIONS "$SUB_A"; az_state APP_ID "app-1"; az_state SP_OID "sp-1"
cd "$TEST_TMP" || exit 1
FOCUS_VERSION=1.1-inherited EXPORT_RECURRENCE=Monthly EXPORT_TIMEFRAME=TheLastMonth \
  KION_HOST=https://k KION_API_KEY=k \
  bash "$S" --tenant-file "$TEST_TMP/t.env" --skip-login >/dev/null
rc=$?
assert_rc_zero "$rc" "inherited export settings run"
assert_az_called "1.1-inherited"
assert_az_called "Monthly"
assert_az_called "TheLastMonth"
teardown_test

setup_test "--only exports runs the export step but skips the app and billing source"
write_tenant
az_state TENANT_ID t-1; az_state ENVIRONMENT_NAME AzureUSGovernment; az_state RG_EXISTS 1; az_state SA_EXISTS 1
az_state BLOB_ENDPOINT "https://sa.blob.core.usgovcloudapi.net/"
az_state SUBSCRIPTIONS "$SUB_A"
cd "$TEST_TMP" || exit 1
KION_HOST=https://k KION_API_KEY=k \
  bash "$S" --tenant-file "$TEST_TMP/t.env" --skip-login --only exports >/dev/null
rc=$?
assert_rc_zero "$rc" "--only exports run"
assert_az_called "rest --method put"
assert_az_not_called "ad app"
[ -s "$TEST_TMP/curl.log" ] && fail "must not register a billing source with --only exports"
teardown_test

setup_test "--only kion-source runs the app and billing source but skips creating exports"
write_tenant
az_state TENANT_ID t-1; az_state ENVIRONMENT_NAME AzureUSGovernment; az_state RG_EXISTS 1; az_state SA_EXISTS 1
az_state BLOB_ENDPOINT "https://sa.blob.core.usgovcloudapi.net/"
az_state SUBSCRIPTIONS "$SUB_A"; az_state APP_ID "app-1"; az_state SP_OID "sp-1"
cd "$TEST_TMP" || exit 1
KION_HOST=https://k KION_API_KEY=k \
  bash "$S" --tenant-file "$TEST_TMP/t.env" --skip-login --only kion-source >/dev/null
rc=$?
assert_rc_zero "$rc" "--only kion-source run"
assert_az_not_called "rest --method put"
assert_curl_called "/v1/payer/standalone"
# Step 3 (which normally reports KION_PREFIX) was skipped entirely, so this
# proves the --print-only recompute path in onboard-tenant.sh still gets the
# right value to the billing source, without ever touching Azure.
assert_curl_stdin_contains "\"focus_storage_prefix\":\"focus/$SUB_A/kion-focus-$SUB_A\""
teardown_test

setup_test "rejects an unknown --only value"
write_tenant
if bash "$S" --tenant-file "$TEST_TMP/t.env" --skip-login --only bogus \
   >/dev/null 2>"$TEST_TMP/err"; then
  fail "expected non-zero exit"
fi
# Must be rejected by --only's own value validation, not just because --only
# itself is an unrecognized flag (that failure mode also mentions "only" and
# would pass before the flag exists at all).
assert_file_contains "$TEST_TMP/err" "exports.*kion-source"
teardown_test

setup_test "passes the exact KION_PREFIX from create-focus-exports.sh to kion-create-billing-source.sh (subscription scope)"
write_tenant
az_state TENANT_ID t-1; az_state ENVIRONMENT_NAME AzureUSGovernment; az_state RG_EXISTS 1; az_state SA_EXISTS 1
az_state BLOB_ENDPOINT "https://sa.blob.core.usgovcloudapi.net/"
az_state SUBSCRIPTIONS "$SUB_A"; az_state APP_ID "app-1"; az_state SP_OID "sp-1"
cd "$TEST_TMP" || exit 1
KION_HOST=https://k KION_API_KEY=k bash "$S" --tenant-file "$TEST_TMP/t.env" --skip-login \
  >/dev/null 2>"$TEST_TMP/err"
rc=$?
assert_rc_zero "$rc" "subscription-scope prefix run"
# The bare EXPORT_PREFIX ("focus") would search a path that never has any
# data (Azure inserts the export name below rootFolderPath); the billing
# source must instead be pointed at "<rootFolderPath>/<export-name>".
assert_curl_stdin_contains "\"focus_storage_prefix\":\"focus/$SUB_A/kion-focus-$SUB_A\""
# ...and the framed banner the operator actually copies from must print that
# same value, byte for byte. These two diverging -- the banner showing the bare
# rootFolderPath while the API call got the real prefix -- is the defect this
# whole branch exists to fix, and it lived in the one channel no test covered.
banner_prefix="$(sed -n 's/^FOCUS prefix:[[:space:]]*//p' "$TEST_TMP/err" | head -1)"
posted_prefix="$(sed -n 's/.*"focus_storage_prefix":"\([^"]*\)".*/\1/p' "$CURL_STDIN_LOG" | head -1)"
[ -n "$banner_prefix" ] || fail "the billing-source banner printed no FOCUS prefix at all"
assert_eq "$banner_prefix" "$posted_prefix"
teardown_test

setup_test "passes the exact KION_PREFIX from create-focus-exports.sh to kion-create-billing-source.sh (billing scope)"
cat > "$TEST_TMP/t.env" <<EOF
TENANT_ID=t-1
AZURE_CLOUD=AzureUSGovernment
BILLING_MODEL=MCA
RESOURCE_GROUP=rg
STORAGE_ACCOUNT=sa
CONTAINER=focus
LOCATION=usgovvirginia
EXPORT_SCOPE=billingAccount
BILLING_SCOPE_ID=/providers/Microsoft.Billing/billingAccounts/ba
KION_PAYER_ID=
EOF
az_state TENANT_ID t-1; az_state ENVIRONMENT_NAME AzureUSGovernment; az_state RG_EXISTS 1; az_state SA_EXISTS 1
az_state BLOB_ENDPOINT "https://sa.blob.core.usgovcloudapi.net/"
az_state APP_ID "app-1"; az_state SP_OID "sp-1"
cd "$TEST_TMP" || exit 1
KION_HOST=https://k KION_API_KEY=k bash "$S" --tenant-file "$TEST_TMP/t.env" --skip-login \
  >/dev/null 2>"$TEST_TMP/err"
rc=$?
assert_rc_zero "$rc" "billing-scope prefix run"
assert_curl_stdin_contains '"focus_storage_prefix":"focus/ba/kion-focus-ba"'
banner_prefix="$(sed -n 's/^FOCUS prefix:[[:space:]]*//p' "$TEST_TMP/err" | head -1)"
assert_eq "$banner_prefix" "focus/ba/kion-focus-ba"
teardown_test

setup_test "EXPORT_SCOPE defaults to billingAccount when the tenant file omits it"
cat > "$TEST_TMP/t.env" <<EOF
TENANT_ID=t-1
AZURE_CLOUD=AzureUSGovernment
BILLING_MODEL=MCA
RESOURCE_GROUP=rg
STORAGE_ACCOUNT=sa
CONTAINER=focus
LOCATION=usgovvirginia
BILLING_SCOPE_ID=/providers/Microsoft.Billing/billingAccounts/ba
KION_PAYER_ID=
EOF
az_state TENANT_ID t-1; az_state ENVIRONMENT_NAME AzureUSGovernment; az_state RG_EXISTS 1; az_state SA_EXISTS 1
az_state BLOB_ENDPOINT "https://sa.blob.core.usgovcloudapi.net/"
az_state APP_ID "app-1"; az_state SP_OID "sp-1"
cd "$TEST_TMP" || exit 1
KION_HOST=https://k KION_API_KEY=k bash "$S" --tenant-file "$TEST_TMP/t.env" --skip-login >/dev/null
rc=$?
assert_rc_zero "$rc" "default-scope run"
assert_az_called "billingAccounts/ba/providers/Microsoft.CostManagement/exports"
assert_az_not_called "account list"
teardown_test

setup_test "EXPORT_SCOPE=subscription with more than one subscription aborts before touching Kion"
write_tenant
az_state TENANT_ID t-1; az_state ENVIRONMENT_NAME AzureUSGovernment; az_state RG_EXISTS 1; az_state SA_EXISTS 1
az_state BLOB_ENDPOINT "https://sa.blob.core.usgovcloudapi.net/"
az_state SUBSCRIPTIONS "$SUB_A,$SUB_B"
cd "$TEST_TMP" || exit 1
if KION_HOST=https://k KION_API_KEY=k bash "$S" --tenant-file "$TEST_TMP/t.env" --skip-login \
   >/dev/null 2>"$TEST_TMP/err"; then
  fail "expected non-zero exit"
fi
assert_file_contains "$TEST_TMP/err" "$SUB_A"
assert_file_contains "$TEST_TMP/err" "$SUB_B"
assert_az_not_called "rest --method put"
[ -s "$TEST_TMP/curl.log" ] && fail "must not register a billing source when exports were never created"
teardown_test

finish_tests
