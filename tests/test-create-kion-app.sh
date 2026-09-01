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

setup_test "warns when tenant domain lookup fails from Graph"
az_state APP_ID "app-42"; az_state SP_OID "sp-1"; az_state TENANT_ID "t-1"
cd "$TEST_TMP"
bash "$S" --resource-group rg --storage-account sa --container focus >/dev/null 2>"$TEST_TMP/err"
assert_file_contains "$TEST_TMP/err" "WARNING.*domain from Microsoft Graph"
teardown_test

finish_tests
