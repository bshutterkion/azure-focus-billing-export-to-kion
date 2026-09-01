#!/bin/bash
set -uo pipefail
. "$(dirname "$0")/lib/harness.sh"
S="$REPO_DIR/scripts/kion-create-billing-source.sh"

new_tenant_file() {
  printf 'TENANT_ID=t-1\nBILLING_MODEL=%s\nAZURE_CLOUD=%s\nKION_PAYER_ID=\n' "$1" "$2" > "$TEST_TMP/t.env"
}
run_bs() {
  KION_HOST=https://kion.example KION_API_KEY=k bash "$S" \
    --tenant-file "$TEST_TMP/t.env" --domain d.onmicrosoft.us --app-id a --client-secret s \
    --endpoint https://sa.blob.core.usgovcloudapi.net/ --container focus --prefix focus "$@"
}

setup_test "posts to kion and records the payer id"
new_tenant_file MCA AzureUSGovernment
export CURL_BODY='{"data":{"id":77}}' CURL_CODE=201
run_bs >/dev/null
assert_curl_called "/v1/payer/standalone"
assert_file_contains "$TEST_TMP/t.env" "KION_PAYER_ID=77"
teardown_test

setup_test "uses the MCA gov account type"
new_tenant_file MCA AzureUSGovernment
run_bs >/dev/null
assert_curl_called '"account_type_id":18'
teardown_test

setup_test "uses the MCA commercial account type"
new_tenant_file MCA AzureCloud
run_bs >/dev/null
assert_curl_called '"account_type_id":16'
teardown_test

setup_test "skips when the tenant already has a payer id"
printf 'TENANT_ID=t-1\nBILLING_MODEL=MCA\nAZURE_CLOUD=AzureCloud\nKION_PAYER_ID=42\n' > "$TEST_TMP/t.env"
run_bs >/dev/null
[ -s "$TEST_TMP/curl.log" ] && fail "should not have called kion"
teardown_test

setup_test "dry run posts nothing"
new_tenant_file MCA AzureCloud
run_bs --dry-run >/dev/null
[ -s "$TEST_TMP/curl.log" ] && fail "dry run must not call kion"
teardown_test

setup_test "non-2xx is a failure"
new_tenant_file MCA AzureCloud
export CURL_CODE=403 CURL_BODY='{"message":"denied"}'
if run_bs >/dev/null 2>"$TEST_TMP/err"; then fail "expected non-zero exit"; fi
teardown_test

finish_tests
