#!/bin/bash
set -uo pipefail
. "$(dirname "$0")/lib/harness.sh"
. "$REPO_DIR/scripts/lib/common.sh"

# check_assert HELPER ARGS... — runs an assert_* helper in a subshell with
# TEST_FAILED reset to 0, and echoes the resulting TEST_FAILED (0 pass / 1
# fail). Because it's a subshell, any TEST_FAILED=1 set by fail() inside it
# never leaks into the enclosing test's TEST_FAILED.
check_assert() {
  ( TEST_FAILED=0; "$@" >/dev/null 2>&1; echo "$TEST_FAILED" )
}

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
summary_add tenant-a ok ok ok ok ok "3 exports"
summary_add tenant-b ok failed - - failed "storage"
out="$(summary_print)"
case "$out" in *tenant-a*ok*) : ;; *) fail "missing tenant-a row" ;; esac
case "$out" in *tenant-b*failed*) : ;; *) fail "missing tenant-b row" ;; esac
assert_eq "$(summary_exit_code)" "1"
summary_reset
summary_add tenant-c ok ok ok ok ok "done"
assert_eq "$(summary_exit_code)" "0"
teardown_test

setup_test "summary carries the spec's per-step columns, not just a status"
summary_reset
summary_add tenant-a ok ok ok warn warn "payer 42 needs its prefix set"
out="$(summary_print)"
# Header names every spec column so an operator can read the row.
for col in TENANT STORAGE EXPORTS APP "BILLING SOURCE" STATUS; do
  case "$out" in *"$col"*) : ;; *) fail "summary header is missing the '$col' column" ;; esac
done
# The row itself must place the cells in that order.
row="$(printf '%s\n' "$out" | grep tenant-a)"
case "$row" in tenant-a*ok*ok*ok*warn*warn*payer\ 42*) : ;;
  *) fail "row cells are not in (tenant, storage, exports, app, billing source, status, detail) order: $row" ;;
esac
teardown_test

setup_test "a warn billing source is exit 0, and only the status column decides the exit code"
summary_reset
summary_add tenant-a ok ok ok warn warn "prefix needs setting by hand"
assert_eq "$(summary_exit_code)" "0"
# A cell reading "failed" in a per-step column must not by itself flip the
# exit code -- only the status column does. (In practice a failed step also
# fails the run, but the exit code must be decided by one field, not by the
# word appearing anywhere in the row.)
summary_reset
summary_add tenant-a ok failed - - warn "exports failed but the run continued"
assert_eq "$(summary_exit_code)" "0"
teardown_test

setup_test "summary_add refuses a stale three-argument caller instead of writing a skewed row"
summary_reset
# This file runs without `set -e`, so the exit code is captured directly; no
# `|| true`, which would discard the very thing under test.
summary_add tenant-a ok "onboarded" 2>"$TEST_TMP/err"
rc=$?
[ "$rc" -ne 0 ] || fail "expected summary_add to reject fewer than 6 fields"
assert_file_contains "$TEST_TMP/err" "summary_add needs 6"
[ -s "$SUMMARY_FILE" ] && fail "a rejected row was still written to the summary"
teardown_test

setup_test "assert_az_called passes when pattern is in AZ_LOG, fails when absent"
echo "account show --query tenantId" >> "$AZ_LOG"
assert_eq "$(check_assert assert_az_called "tenantId")" "0"
assert_eq "$(check_assert assert_az_called "no-such-call")" "1"
teardown_test

setup_test "assert_az_not_called passes when pattern is absent, fails when present"
echo "account show --query tenantId" >> "$AZ_LOG"
assert_eq "$(check_assert assert_az_not_called "no-such-call")" "0"
assert_eq "$(check_assert assert_az_not_called "tenantId")" "1"
teardown_test

setup_test "assert_curl_called passes when pattern is in CURL_LOG, fails when absent"
echo "-sS -X POST https://example.test/api" >> "$CURL_LOG"
assert_eq "$(check_assert assert_curl_called "POST")" "0"
assert_eq "$(check_assert assert_curl_called "no-such-call")" "1"
teardown_test

setup_test "assert_file_contains passes when file has pattern, fails when it does not"
printf 'hello\nworld\n' > "$TEST_TMP/f.txt"
assert_eq "$(check_assert assert_file_contains "$TEST_TMP/f.txt" "wor")" "0"
assert_eq "$(check_assert assert_file_contains "$TEST_TMP/f.txt" "no-such-pattern")" "1"
teardown_test

finish_tests
