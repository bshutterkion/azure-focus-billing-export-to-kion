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

setup_test "tenant file with no AZURE_CLOUD falls back to the inherited environment, not Commercial"
cat > "$TEST_TMP/t.env" <<EOF
TENANT_ID=t-1
BILLING_MODEL=MCA
RESOURCE_GROUP=rg
STORAGE_ACCOUNT=sa
CONTAINER=focus
LOCATION=usgovvirginia
KION_PAYER_ID=
EOF
az_state TENANT_ID t-1; az_state RG_EXISTS 1; az_state SA_EXISTS 1
az_state BLOB_ENDPOINT "https://sa.blob.core.usgovcloudapi.net/"
az_state SUBSCRIPTIONS "sub-a"; az_state APP_ID "app-1"; az_state SP_OID "sp-1"
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
az_state SUBSCRIPTIONS "sub-a"
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

finish_tests
