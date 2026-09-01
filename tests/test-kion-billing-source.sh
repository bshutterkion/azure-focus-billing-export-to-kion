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
assert_curl_stdin_contains '"account_type_id":18'
teardown_test

setup_test "uses the MCA commercial account type"
new_tenant_file MCA AzureCloud
run_bs >/dev/null
assert_curl_stdin_contains '"account_type_id":16'
teardown_test

setup_test "an already-onboarded tenant creates nothing and exits 3, not 0"
printf 'TENANT_ID=t-1\nBILLING_MODEL=MCA\nAZURE_CLOUD=AzureCloud\nKION_PAYER_ID=42\n' > "$TEST_TMP/t.env"
# A distinct prefix fixture, deliberately unlike anything in the warning text.
# With `--prefix focus`, `assert_file_contains err "focus"` matched the literal
# "focus_storage_prefix" inside the message, so blanking the printed value left
# this test green. `run_bs`'s own --prefix comes first, so this one wins.
run_bs --prefix zzz-prefix-check >/dev/null 2>"$TEST_TMP/err"
rc=$?
# Exit 3, not 0: "onboarded, but its FOCUS prefix still needs setting by hand"
# has to be distinguishable by a caller building a summary, because stderr does
# not reach a summary table.
assert_eq "$rc" "3"
[ -s "$TEST_TMP/curl.log" ] && fail "should not have called kion"
# The warning must be actionable without re-deriving anything: it has to name
# the existing payer id and the correct prefix, and say plainly that the
# prefix was not updated (Kion has no API for editing an existing Azure
# billing source, so this warning is the only place an operator learns to go
# set it in the Kion UI).
assert_file_contains "$TEST_TMP/err" "42"
assert_file_contains "$TEST_TMP/err" "zzz-prefix-check"
assert_file_contains "$TEST_TMP/err" "NOT updated"
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

setup_test "keeps the client secret and Kion API key out of curl argv"
new_tenant_file MCA AzureCloud
export CURL_BODY='{"data":{"id":9}}' CURL_CODE=201
KION_HOST=https://kion.example KION_API_KEY=zzz-kion-secret-999 bash "$S" \
  --tenant-file "$TEST_TMP/t.env" --domain d.onmicrosoft.com --app-id a \
  --client-secret zzz-client-secret-888 \
  --endpoint https://sa.blob.core.windows.net/ --container focus --prefix focus >/dev/null
assert_curl_argv_lacks "zzz-client-secret-888"
assert_curl_argv_lacks "zzz-kion-secret-999"
teardown_test

setup_test "request still carries the right body and Authorization header"
new_tenant_file MCA AzureCloud
export CURL_BODY='{"data":{"id":9}}' CURL_CODE=201
KION_HOST=https://kion.example KION_API_KEY=zzz-kion-secret-999 bash "$S" \
  --tenant-file "$TEST_TMP/t.env" --domain d.onmicrosoft.com --app-id a \
  --client-secret zzz-client-secret-888 \
  --endpoint https://sa.blob.core.windows.net/ --container focus --prefix focus >/dev/null
assert_curl_stdin_contains "Authorization: Bearer zzz-kion-secret-999"
assert_curl_stdin_contains '"client_secret":"zzz-client-secret-888"'
assert_curl_stdin_contains '"domain":"d.onmicrosoft.com"'
teardown_test

setup_test "2xx with no payer id fails loudly and leaves the tenant file untouched"
new_tenant_file MCA AzureCloud
before="$(cat "$TEST_TMP/t.env")"
export CURL_BODY='{"data":{}}' CURL_CODE=201
set +e
run_bs >/dev/null 2>"$TEST_TMP/err"
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "expected non-zero exit when no payer id can be extracted"
assert_file_contains "$TEST_TMP/err" "$TEST_TMP/t.env"
after="$(cat "$TEST_TMP/t.env")"
[ "$before" = "$after" ] || fail "tenant file was modified despite the failure"
teardown_test

setup_test "write-back preserves the tenant file's mode and other keys"
new_tenant_file MCA AzureCloud
# 640, not 600: mktemp's own default mode is 600, so a fixture already at 600
# would pass even if the fix never restored the original mode at all.
chmod 640 "$TEST_TMP/t.env"
export CURL_BODY='{"data":{"id":55}}' CURL_CODE=201
run_bs >/dev/null
assert_eq "$(stat -f '%Lp' "$TEST_TMP/t.env" 2>/dev/null || stat -c '%a' "$TEST_TMP/t.env")" "640"
assert_file_contains "$TEST_TMP/t.env" "KION_PAYER_ID=55"
assert_file_contains "$TEST_TMP/t.env" "TENANT_ID=t-1"
assert_file_contains "$TEST_TMP/t.env" "BILLING_MODEL=MCA"
teardown_test

setup_test "a stat that produces nothing does not fail the script after a successful write-back"
new_tenant_file MCA AzureCloud
# Fake stat: always fails with no output, on both the BSD (-f) and GNU (-c)
# forms kion-create-billing-source.sh tries. $TEST_TMP/bin is already first
# on PATH (harness.sh puts the az/curl stubs there), so this fake is found
# before the real stat for this test only; no other test is affected.
cat > "$TEST_TMP/bin/stat" <<'EOF'
#!/bin/bash
exit 1
EOF
chmod +x "$TEST_TMP/bin/stat"
export CURL_BODY='{"data":{"id":99}}' CURL_CODE=201
set +e
run_bs >/dev/null 2>"$TEST_TMP/err"
rc=$?
set -e
assert_eq "$rc" "0"
assert_file_contains "$TEST_TMP/err" "recorded KION_PAYER_ID=99"
assert_file_contains "$TEST_TMP/t.env" "KION_PAYER_ID=99"
teardown_test

finish_tests
