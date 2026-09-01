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

# Every test above replaces onboard-tenant.sh with a fake, so nothing exercises
# the real controller through the loop -- which is exactly how a summary row
# reading "ok" for a run that never updated Kion's prefix stayed hidden. These
# two run the real onboard-tenant.sh against the az/curl stubs.
real_seam_tenants() {
  mkdir -p "$TEST_TMP/tenants"
  # Both tenants are the same tenant id because the az stub answers
  # `account show --query tenantId` from a single shared state file; the tenant
  # files differ in what matters here, whether KION_PAYER_ID is already set.
  cat > "$TEST_TMP/tenants/fresh.env" <<EOF
TENANT_ID=t-1
AZURE_CLOUD=AzureUSGovernment
BILLING_MODEL=MCA
RESOURCE_GROUP=rg
STORAGE_ACCOUNT=sa
CONTAINER=focus
EXPORT_SCOPE=billingAccount
BILLING_SCOPE_ID=/providers/Microsoft.Billing/billingAccounts/ba
KION_PAYER_ID=
EOF
  sed 's/^KION_PAYER_ID=$/KION_PAYER_ID=42/' "$TEST_TMP/tenants/fresh.env" \
    > "$TEST_TMP/tenants/already.env"
}

setup_test "real onboard-tenant.sh through the loop: a fresh tenant is ok and records its payer id"
real_seam_tenants
az_state TENANT_ID t-1; az_state RG_EXISTS 1; az_state SA_EXISTS 1
az_state BLOB_ENDPOINT "https://sa.blob.core.usgovcloudapi.net/"
az_state APP_ID "app-1"; az_state SP_OID "sp-1"
cd "$TEST_TMP" || exit 1
out="$(KION_HOST=https://k KION_API_KEY=k bash "$S" --dir "$TEST_TMP/tenants" 2>&1)"
rc=$?
[ "$rc" -eq 0 ] || fail "expected exit 0, got $rc"
row="$(printf '%s\n' "$out" | grep '^fresh ')"
[ -n "$row" ] || fail "no summary row for the fresh tenant"
# Field 6 is the status column: tenant, storage, exports, app, billing source,
# status. Matching "ok" anywhere in the row would match the per-step cells too.
assert_eq "$(printf '%s\n' "$row" | awk '{print $6}')" "ok"
assert_eq "$(printf '%s\n' "$row" | awk '{print $5}')" "ok"
assert_file_contains "$TEST_TMP/tenants/fresh.env" "^KION_PAYER_ID=1$"
teardown_test

setup_test "real onboard-tenant.sh through the loop: an already-onboarded tenant is warn, not ok"
real_seam_tenants
az_state TENANT_ID t-1; az_state RG_EXISTS 1; az_state SA_EXISTS 1
az_state BLOB_ENDPOINT "https://sa.blob.core.usgovcloudapi.net/"
az_state APP_ID "app-1"; az_state SP_OID "sp-1"
cd "$TEST_TMP" || exit 1
out="$(KION_HOST=https://k KION_API_KEY=k bash "$S" --dir "$TEST_TMP/tenants" 2>&1)"
rc=$?
# A warning, not a failure: the tenant is onboarded, so the run still exits 0.
[ "$rc" -eq 0 ] || fail "expected exit 0 for a warn-only run, got $rc"
row="$(printf '%s\n' "$out" | grep '^already ')"
[ -n "$row" ] || fail "no summary row for the already-onboarded tenant"
# Field 5 is the billing-source cell, field 6 the status. Both must say warn:
# a bare "ok" in either is the failure this item is about -- the tenant is
# onboarded, but its FOCUS prefix still needs setting by hand in the Kion UI,
# and the summary is the one line an operator reads.
assert_eq "$(printf '%s\n' "$row" | awk '{print $5}')" "warn"
assert_eq "$(printf '%s\n' "$row" | awk '{print $6}')" "warn"
case "$row" in *42*) : ;; *) fail "row detail does not name the payer id that needs attention: $row" ;; esac
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
