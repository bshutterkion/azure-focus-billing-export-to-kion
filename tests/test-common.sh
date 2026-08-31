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
