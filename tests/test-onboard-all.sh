#!/bin/bash
set -uo pipefail
. "$(dirname "$0")/lib/harness.sh"
S="$REPO_DIR/scripts/onboard-all.sh"

make_tenants() {
  mkdir -p "$TEST_TMP/tenants"
  for n in "$@"; do
    printf 'TENANT_ID=%s\nRESOURCE_GROUP=rg\nSTORAGE_ACCOUNT=sa\nCONTAINER=focus\nKION_PAYER_ID=\n' "$n" \
      > "$TEST_TMP/tenants/$n.env"
  done
}
stub_onboard_tenant() {
  mkdir -p "$TEST_TMP/bin"
  cat > "$TEST_TMP/bin/onboard-tenant.sh" <<EOF
#!/bin/bash
echo "\$*" >> "$TEST_TMP/onboard-tenant.calls"
$1
EOF
  chmod +x "$TEST_TMP/bin/onboard-tenant.sh"
}

setup_test "one failing tenant does not stop the others"
make_tenants alpha beta
stub_onboard_tenant 'case "$*" in *alpha*) echo "boom" >&2; exit 1 ;; *) exit 0 ;; esac'
out="$(ONBOARD_TENANT_BIN="$TEST_TMP/bin/onboard-tenant.sh" bash "$S" --dir "$TEST_TMP/tenants" 2>&1)"
case "$out" in *alpha*failed*) : ;; *) fail "alpha not reported failed" ;; esac
case "$out" in *beta*ok*) : ;; *) fail "beta not reported ok" ;; esac
teardown_test

setup_test "exits non-zero when any tenant failed"
make_tenants alpha
stub_onboard_tenant 'exit 1'
if ONBOARD_TENANT_BIN="$TEST_TMP/bin/onboard-tenant.sh" bash "$S" --dir "$TEST_TMP/tenants" >/dev/null 2>&1; then
  fail "expected non-zero exit"
fi
# Guard against a false pass from onboard-all.sh itself not existing/running
# (bash would also exit non-zero for a missing file) by requiring proof the
# stub actually ran.
[ -s "$TEST_TMP/onboard-tenant.calls" ] || fail "onboard-tenant stub was never invoked"
teardown_test

setup_test "exits zero when all tenants succeed"
make_tenants alpha beta
stub_onboard_tenant 'exit 0'
ONBOARD_TENANT_BIN="$TEST_TMP/bin/onboard-tenant.sh" bash "$S" --dir "$TEST_TMP/tenants" >/dev/null 2>&1 \
  || fail "expected zero exit"
teardown_test

setup_test "skips a tenant file with no TENANT_ID and logs why"
mkdir -p "$TEST_TMP/tenants"
printf 'RESOURCE_GROUP=rg\nSTORAGE_ACCOUNT=sa\nCONTAINER=focus\nKION_PAYER_ID=\n' > "$TEST_TMP/tenants/blank.env"
make_tenants alpha
stub_onboard_tenant 'exit 0'
out="$(ONBOARD_TENANT_BIN="$TEST_TMP/bin/onboard-tenant.sh" bash "$S" --dir "$TEST_TMP/tenants" 2>&1)"
case "$out" in *blank.env*TENANT_ID*|*TENANT_ID*blank.env*) : ;; *) fail "did not log why blank.env was skipped" ;; esac
case "$out" in *alpha*ok*) : ;; *) fail "alpha not reported ok" ;; esac
teardown_test

setup_test "exits non-zero with a clear error when the directory has no tenant files"
mkdir -p "$TEST_TMP/tenants"
if ONBOARD_TENANT_BIN=/bin/true bash "$S" --dir "$TEST_TMP/tenants" >/dev/null 2>"$TEST_TMP/err"; then
  fail "expected non-zero exit"
fi
assert_file_contains "$TEST_TMP/err" "no tenant files"
teardown_test

setup_test "make status makes no Azure or Kion calls"
make_tenants alpha beta
out="$(cd "$REPO_DIR" && make status TENANTS_DIR="$TEST_TMP/tenants" 2>&1)"
[ -s "$AZ_LOG" ] && fail "make status made an az call"
[ -s "$CURL_LOG" ] && fail "make status made a curl call"
case "$out" in *alpha*) : ;; *) fail "status output did not mention alpha" ;; esac
case "$out" in *beta*) : ;; *) fail "status output did not mention beta" ;; esac
teardown_test

finish_tests
