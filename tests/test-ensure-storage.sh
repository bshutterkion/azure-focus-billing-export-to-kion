#!/bin/bash
set -uo pipefail
. "$(dirname "$0")/lib/harness.sh"
S="$REPO_DIR/scripts/ensure-storage.sh"

SUB_A="aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"

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

setup_test "fails when container creation fails on both auth modes"
az_state RG_EXISTS 1; az_state SA_EXISTS 1
export AZ_FAIL_MATCH="storage container create"
out="$(bash "$S" --resource-group rg1 --storage-account sa1 --container focus 2>"$TEST_TMP/err")"
rc=$?
unset AZ_FAIL_MATCH
assert_eq "$rc" "1"
assert_file_contains "$TEST_TMP/err" "could not create container"
assert_eq "$out" ""
teardown_test

# Without --subscription every call below resolves against whichever
# subscription `az login` happened to make active, which is not a choice anyone
# made. One un-flagged call is worse than none: the resource group would be
# read from one subscription and the storage account created in another.
setup_test "--subscription reaches every resource-group, storage and container call"
az_state RG_EXISTS 0; az_state SA_EXISTS 0
az_state BLOB_ENDPOINT "https://sa.blob.core.usgovcloudapi.net/"
bash "$S" --resource-group rg1 --storage-account sa1 --container focus \
  --location usgovvirginia --subscription "$SUB_A" >/dev/null
rc=$?
assert_eq "$rc" "0"
assert_az_called "group show .*--subscription $SUB_A"
assert_az_called "group create .*--subscription $SUB_A"
assert_az_called "storage account show .*--subscription $SUB_A"
assert_az_called "storage account create .*--subscription $SUB_A"
assert_az_called "storage container create .*--subscription $SUB_A"
teardown_test

# Both container-create auth modes have to carry it, not just the first: the
# AAD attempt usually fails on a freshly created account, so the key fallback
# is the call that actually creates the container in practice.
setup_test "--subscription reaches the key-auth container fallback too"
az_state RG_EXISTS 1; az_state SA_EXISTS 1
az_state BLOB_ENDPOINT "https://sa.blob.core.usgovcloudapi.net/"
export AZ_FAIL_MATCH="storage container create.*--auth-mode login"
bash "$S" --resource-group rg1 --storage-account sa1 --container focus \
  --subscription "$SUB_A" >/dev/null
rc=$?
unset AZ_FAIL_MATCH
assert_eq "$rc" "0"
assert_az_called "storage container create.*--auth-mode key.*--subscription $SUB_A"
teardown_test

setup_test "sends no --subscription flag when none is given"
az_state RG_EXISTS 1; az_state SA_EXISTS 1
az_state BLOB_ENDPOINT "https://sa.blob.core.usgovcloudapi.net/"
bash "$S" --resource-group rg1 --storage-account sa1 --container focus >/dev/null
assert_az_not_called "--subscription"
teardown_test

finish_tests
