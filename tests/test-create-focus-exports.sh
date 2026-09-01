#!/bin/bash
set -uo pipefail
. "$(dirname "$0")/lib/harness.sh"
S="$REPO_DIR/scripts/create-focus-exports.sh"
SAID="/subscriptions/s1/resourceGroups/rg/providers/Microsoft.Storage/storageAccounts/sa"

setup_test "subscription scope with more than one subscription fails hard and creates nothing"
if bash "$S" --storage-account-id "$SAID" --container focus --prefix focus \
   --subscriptions "sub-a sub-b" >/dev/null 2>"$TEST_TMP/err"; then fail "expected non-zero exit"; fi
assert_file_contains "$TEST_TMP/err" "sub-a"
assert_file_contains "$TEST_TMP/err" "sub-b"
assert_file_contains "$TEST_TMP/err" "billingAccount"
assert_az_not_called "rest --method put"
teardown_test

setup_test "subscription scope with exactly one subscription still succeeds"
bash "$S" --storage-account-id "$SAID" --container focus --prefix focus \
  --subscriptions "sub-a" >/dev/null
rc=$?
assert_eq "$rc" "0"
assert_az_called "rest --method put"
teardown_test

setup_test "auto-enumerated subscriptions also trigger the hard fail"
az_state SUBSCRIPTIONS "sub-x,sub-y"
if bash "$S" --storage-account-id "$SAID" --container focus --prefix focus >/dev/null 2>"$TEST_TMP/err"; then
  fail "expected non-zero exit"
fi
assert_file_contains "$TEST_TMP/err" "sub-x"
assert_file_contains "$TEST_TMP/err" "sub-y"
assert_az_not_called "rest --method put"
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

setup_test "enumerates a single subscription when none are given"
az_state SUBSCRIPTIONS "sub-x"
bash "$S" --storage-account-id "$SAID" --container focus --prefix focus >/dev/null
assert_az_called "account list"
assert_az_called "subscriptions/sub-x/providers"
teardown_test

setup_test "non-subscription scope requires a billing scope id"
if bash "$S" --storage-account-id "$SAID" --container focus --prefix focus \
   --scope billingProfile >/dev/null 2>"$TEST_TMP/err"; then fail "expected non-zero exit"; fi
assert_file_contains "$TEST_TMP/err" "billing-scope-id"
teardown_test

# 2023-08-01 and earlier only accept ActualCost/AmortizedCost/Usage in
# definition.type; FocusCost (which this script always sends) needs a later
# "enhanced exports" api-version, so the default must not be 2023-08-01.
setup_test "defaults to api-version 2025-03-01, the first version that accepts FocusCost"
bash "$S" --storage-account-id "$SAID" --container focus --prefix focus \
  --subscriptions "sub-a" >/dev/null
assert_az_called "api-version=2025-03-01"
teardown_test

setup_test "--api-version overrides the default"
bash "$S" --storage-account-id "$SAID" --container focus --prefix focus \
  --subscriptions "sub-a" --api-version 2023-08-01 >/dev/null
assert_az_called "api-version=2023-08-01"
grep -q "api-version=2025-03-01" "$TEST_TMP/az.log" && fail "override did not reach the url; default leaked through"
teardown_test

setup_test "KION_PREFIX equals rootFolderPath/export-name for a subscription-scope export"
OUT="$(bash "$S" --storage-account-id "$SAID" --container focus --prefix focus --subscriptions "sub-a")"
KION_PREFIX="$(printf '%s\n' "$OUT" | sed -n 's/^KION_PREFIX=//p')"
assert_eq "$KION_PREFIX" "focus/sub-a/kion-focus-sub-a"
teardown_test

setup_test "KION_PREFIX equals rootFolderPath/export-name for a billing-scope export"
OUT="$(bash "$S" --storage-account-id "$SAID" --container focus --prefix focus \
  --scope billingProfile --billing-scope-id "/providers/Microsoft.Billing/billingAccounts/ba/billingProfiles/bp")"
KION_PREFIX="$(printf '%s\n' "$OUT" | sed -n 's/^KION_PREFIX=//p')"
assert_eq "$KION_PREFIX" "focus/bp/kion-focus-bp"
teardown_test

setup_test "--print-only reports KION_PREFIX without creating or running anything"
OUT="$(bash "$S" --storage-account-id "$SAID" --container focus --prefix focus --subscriptions "sub-a" --print-only)"
assert_az_not_called "rest --method put"
assert_az_not_called "rest --method post"
KION_PREFIX="$(printf '%s\n' "$OUT" | sed -n 's/^KION_PREFIX=//p')"
assert_eq "$KION_PREFIX" "focus/sub-a/kion-focus-sub-a"
teardown_test

setup_test "--print-only still hard-fails when subscription scope has more than one subscription"
if bash "$S" --storage-account-id "$SAID" --container focus --prefix focus \
   --subscriptions "sub-a sub-b" --print-only >/dev/null 2>"$TEST_TMP/err"; then fail "expected non-zero exit"; fi
assert_az_not_called "rest --method put"
teardown_test

setup_test "an MCA billing account id with a colon produces a valid, deterministic export name"
MCA_ID="12345678-1234-1234-1234-123456789012:87654321-4321-4321-4321-210987654321_2019-05-31"
OUT1="$(bash "$S" --storage-account-id "$SAID" --container focus --prefix focus \
  --scope billingAccount --billing-scope-id "/providers/Microsoft.Billing/billingAccounts/$MCA_ID")"
NAME1="$(printf '%s\n' "$OUT1" | sed -n '1p')"
OUT2="$(bash "$S" --storage-account-id "$SAID" --container focus --prefix focus \
  --scope billingAccount --billing-scope-id "/providers/Microsoft.Billing/billingAccounts/$MCA_ID")"
NAME2="$(printf '%s\n' "$OUT2" | sed -n '1p')"
assert_eq "$NAME1" "$NAME2"
printf '%s' "$NAME1" | grep -qE '^[A-Za-z0-9_-]+$' || fail "export name '$NAME1' contains characters Azure resource names can't carry"
[ "${#NAME1}" -le 64 ] || fail "export name '$NAME1' is ${#NAME1} chars, over the 64-char limit"
teardown_test

setup_test "run-now POST is issued after the export PUT"
bash "$S" --storage-account-id "$SAID" --container focus --prefix focus --subscriptions "sub-a" >/dev/null
put_line="$(grep -n 'method put' "$TEST_TMP/az.log" | head -1 | cut -d: -f1)"
run_line="$(grep -n 'run?api-version' "$TEST_TMP/az.log" | head -1 | cut -d: -f1)"
[ -n "$put_line" ] || fail "PUT was not recorded"
[ -n "$run_line" ] || fail "run-now POST was not recorded"
[ -n "$put_line" ] && [ -n "$run_line" ] && [ "$put_line" -lt "$run_line" ] || fail "expected run-now POST after the PUT, got put=$put_line run=$run_line"
assert_az_called 'rest --method post.*run\?api-version'
teardown_test

setup_test "--no-run-now skips triggering an on-demand run"
bash "$S" --storage-account-id "$SAID" --container focus --prefix focus --subscriptions "sub-a" --no-run-now >/dev/null
assert_az_called "rest --method put"
assert_az_not_called 'run\?api-version'
teardown_test

setup_test "a failing run-now POST is a warning, not an error"
export AZ_FAIL_MATCH='run\?api-version'
bash "$S" --storage-account-id "$SAID" --container focus --prefix focus --subscriptions "sub-a" >/dev/null 2>"$TEST_TMP/err"
rc=$?
unset AZ_FAIL_MATCH
assert_eq "$rc" "0"
assert_az_called "rest --method put"
assert_file_contains "$TEST_TMP/err" "WARNING"
teardown_test

finish_tests
