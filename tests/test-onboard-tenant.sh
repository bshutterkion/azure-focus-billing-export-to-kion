#!/bin/bash
set -uo pipefail
. "$(dirname "$0")/lib/harness.sh"
S="$REPO_DIR/scripts/onboard-tenant.sh"

# Bare GUID-shaped subscription id fixtures, matching the shape
# create-focus-exports.sh's subscription-id guard now requires.
SUB_A="aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
SUB_B="bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"

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
az_state TENANT_ID t-1; az_state RG_EXISTS 1; az_state SA_EXISTS 1
az_state BLOB_ENDPOINT "https://sa.blob.core.usgovcloudapi.net/"
az_state SUBSCRIPTIONS "$SUB_A"; az_state APP_ID "app-1"; az_state SP_OID "sp-1"
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
az_state SUBSCRIPTIONS "$SUB_A"
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
az_state TENANT_ID t-1; az_state RG_EXISTS 1; az_state SA_EXISTS 1
az_state BLOB_ENDPOINT "https://sa.blob.core.usgovcloudapi.net/"
az_state SUBSCRIPTIONS "$SUB_A"; az_state APP_ID "app-1"; az_state SP_OID "sp-1"
cd "$TEST_TMP"
AZURE_CLOUD=AzureUSGovernment KION_HOST=https://k KION_API_KEY=k \
  bash "$S" --tenant-file "$TEST_TMP/t.env" --skip-login >/dev/null
# resolve_cloud falls back to the Gov literals when `az cloud show` returns
# nothing (as the stub does here), so a Gov-specific ARM endpoint reaching the
# FOCUS export's `az rest` call proves AZURE_CLOUD carried through as Gov
# rather than being reset to the AzureCloud default.
assert_az_called "usgovcloudapi.net"
teardown_test

setup_test "aborts before any curl call when create-kion-app.sh yields no APP_ID"
write_tenant
az_state TENANT_ID t-1; az_state RG_EXISTS 1; az_state SA_EXISTS 1
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
cd "$TEST_TMP"
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
az_state TENANT_ID t-1; az_state RG_EXISTS 1; az_state SA_EXISTS 1
az_state BLOB_ENDPOINT "https://sa.blob.core.usgovcloudapi.net/"
az_state SUBSCRIPTIONS "$SUB_A"; az_state APP_ID "app-1"; az_state SP_OID "sp-1"
cd "$TEST_TMP"
EXPORT_API_VERSION=2023-08-01 KION_HOST=https://k KION_API_KEY=k \
  bash "$S" --tenant-file "$TEST_TMP/t.env" --skip-login >/dev/null
assert_az_called "api-version=2025-03-01"
grep -q "api-version=2023-08-01" "$TEST_TMP/az.log" && fail "tenant file value did not win over the inherited .env default"
teardown_test

setup_test "EXPORT_API_VERSION: inherited .env default flows through when the tenant file omits it"
write_tenant
az_state TENANT_ID t-1; az_state RG_EXISTS 1; az_state SA_EXISTS 1
az_state BLOB_ENDPOINT "https://sa.blob.core.usgovcloudapi.net/"
az_state SUBSCRIPTIONS "$SUB_A"; az_state APP_ID "app-1"; az_state SP_OID "sp-1"
cd "$TEST_TMP"
EXPORT_API_VERSION=9999-01-01 KION_HOST=https://k KION_API_KEY=k \
  bash "$S" --tenant-file "$TEST_TMP/t.env" --skip-login >/dev/null
assert_az_called "api-version=9999-01-01"
teardown_test

setup_test "--only exports runs the export step but skips the app and billing source"
write_tenant
az_state TENANT_ID t-1; az_state RG_EXISTS 1; az_state SA_EXISTS 1
az_state BLOB_ENDPOINT "https://sa.blob.core.usgovcloudapi.net/"
az_state SUBSCRIPTIONS "$SUB_A"
cd "$TEST_TMP"
KION_HOST=https://k KION_API_KEY=k \
  bash "$S" --tenant-file "$TEST_TMP/t.env" --skip-login --only exports >/dev/null
assert_az_called "rest --method put"
assert_az_not_called "ad app"
[ -s "$TEST_TMP/curl.log" ] && fail "must not register a billing source with --only exports"
teardown_test

setup_test "--only kion-source runs the app and billing source but skips creating exports"
write_tenant
az_state TENANT_ID t-1; az_state RG_EXISTS 1; az_state SA_EXISTS 1
az_state BLOB_ENDPOINT "https://sa.blob.core.usgovcloudapi.net/"
az_state SUBSCRIPTIONS "$SUB_A"; az_state APP_ID "app-1"; az_state SP_OID "sp-1"
cd "$TEST_TMP"
KION_HOST=https://k KION_API_KEY=k \
  bash "$S" --tenant-file "$TEST_TMP/t.env" --skip-login --only kion-source >/dev/null
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
az_state TENANT_ID t-1; az_state RG_EXISTS 1; az_state SA_EXISTS 1
az_state BLOB_ENDPOINT "https://sa.blob.core.usgovcloudapi.net/"
az_state SUBSCRIPTIONS "$SUB_A"; az_state APP_ID "app-1"; az_state SP_OID "sp-1"
cd "$TEST_TMP"
KION_HOST=https://k KION_API_KEY=k bash "$S" --tenant-file "$TEST_TMP/t.env" --skip-login >/dev/null
# The bare EXPORT_PREFIX ("focus") would search a path that never has any
# data (Azure inserts the export name below rootFolderPath); the billing
# source must instead be pointed at "<rootFolderPath>/<export-name>".
assert_curl_stdin_contains "\"focus_storage_prefix\":\"focus/$SUB_A/kion-focus-$SUB_A\""
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
az_state TENANT_ID t-1; az_state RG_EXISTS 1; az_state SA_EXISTS 1
az_state BLOB_ENDPOINT "https://sa.blob.core.usgovcloudapi.net/"
az_state APP_ID "app-1"; az_state SP_OID "sp-1"
cd "$TEST_TMP"
KION_HOST=https://k KION_API_KEY=k bash "$S" --tenant-file "$TEST_TMP/t.env" --skip-login >/dev/null
assert_curl_stdin_contains '"focus_storage_prefix":"focus/ba/kion-focus-ba"'
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
az_state TENANT_ID t-1; az_state RG_EXISTS 1; az_state SA_EXISTS 1
az_state BLOB_ENDPOINT "https://sa.blob.core.usgovcloudapi.net/"
az_state APP_ID "app-1"; az_state SP_OID "sp-1"
cd "$TEST_TMP"
KION_HOST=https://k KION_API_KEY=k bash "$S" --tenant-file "$TEST_TMP/t.env" --skip-login >/dev/null
assert_az_called "billingAccounts/ba/providers/Microsoft.CostManagement/exports"
assert_az_not_called "account list"
teardown_test

setup_test "EXPORT_SCOPE=subscription with more than one subscription aborts before touching Kion"
write_tenant
az_state TENANT_ID t-1; az_state RG_EXISTS 1; az_state SA_EXISTS 1
az_state BLOB_ENDPOINT "https://sa.blob.core.usgovcloudapi.net/"
az_state SUBSCRIPTIONS "$SUB_A,$SUB_B"
cd "$TEST_TMP"
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
