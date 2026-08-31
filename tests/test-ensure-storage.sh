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
