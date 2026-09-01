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

finish_tests
