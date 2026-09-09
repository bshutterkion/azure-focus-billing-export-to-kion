#!/bin/bash
set -uo pipefail
. "$(dirname "$0")/lib/harness.sh"
S="$REPO_DIR/scripts/preflight-tenants.sh"

# row FILE NAME -> the surveyed row for that tenant, tabs turned to '|' so a
# test can assert on whole fields without fighting $IFS.
row() { sed -n "s/^$2	/$2|/p" "$1" | tr '\t' '|' | head -1; }
field() { printf '%s' "$1" | awk -F'|' -v n="$2" '{print $n}'; }

# A tenant that has everything a run needs: Owner at the root management
# group, one visible billing account, and every subscription billing to a
# single profile within it.
ready_state() {
  az_state TENANT_ID "t1"
  az_state ENVIRONMENT_NAME "AzureCloud"
  az_state SUBSCRIPTIONS_t1 "sub-a,sub-b"
  az_state SIGNED_IN_OID "oid-1"
  az_state MG_ROLES "Owner"
  az_state BILLING_ACCOUNTS "acct-1"
  az_state BILLING_SUBS_acct-1 "sub-a|prof-1,sub-b|prof-1"
}

setup_test "surveys a ready tenant and prefers the narrower profile scope"
ready_state
out="$TEST_TMP/out"
bash "$S" --tenant-id t1 --no-login >"$out" 2>/dev/null
r="$(row "$out" t1)"
assert_eq "$(field "$r" 3)" "AzureCloud"
assert_eq "$(field "$r" 4)" "2"
assert_eq "$(field "$r" 5)" "Owner"
assert_eq "$(field "$r" 6)" "acct-1"
assert_eq "$(field "$r" 7)" "prof-1"
# billingProfile, not billingAccount: from inside one tenant it is impossible
# to prove no other tenant bills to the same account, so the scope that is
# provably no broader than this tenant is the correct recommendation.
assert_eq "$(field "$r" 8)" "billingProfile"
assert_eq "$(field "$r" 9)" "ready"
teardown_test

setup_test "emits a header row and nothing but data on stdout"
ready_state
out="$TEST_TMP/out"
bash "$S" --tenant-id t1 --no-login >"$out" 2>/dev/null
assert_eq "$(head -1 "$out" | tr '\t' '|')" \
  "NAME|TENANT_ID|CLOUD|SUBS|MG_ROLE|BILLING_ACCOUNT|BILLING_PROFILE|EXPORT_SCOPE|VERDICT|NOTE"
assert_eq "$(wc -l <"$out" | tr -d ' ')" "2"
teardown_test

setup_test "blocks a tenant with no Owner or User Access Administrator at root"
ready_state
az_state MG_ROLES "Reader"
out="$TEST_TMP/out"
bash "$S" --tenant-id t1 --no-login >"$out" 2>/dev/null
r="$(row "$out" t1)"
assert_eq "$(field "$r" 9)" "blocked"
printf '%s' "$r" | grep -q "management group" || fail "note should name the management group"
teardown_test

setup_test "accepts User Access Administrator as sufficient"
ready_state
az_state MG_ROLES "User Access Administrator"
out="$TEST_TMP/out"
bash "$S" --tenant-id t1 --no-login >"$out" 2>/dev/null
assert_eq "$(field "$(row "$out" t1)" 9)" "ready"
teardown_test

setup_test "blocks a tenant whose billing account is not visible"
ready_state
az_state BILLING_ACCOUNTS ""
out="$TEST_TMP/out"
bash "$S" --tenant-id t1 --no-login >"$out" 2>/dev/null
r="$(row "$out" t1)"
assert_eq "$(field "$r" 9)" "blocked"
printf '%s' "$r" | grep -q "billing role" || fail "note should name the missing billing role"
teardown_test

setup_test "flags a tenant whose subscriptions span more than one profile"
# The shared-billing-account case that has no correct per-tenant export scope:
# neither billingAccount (too broad, other tenants' costs) nor any single
# profile (too narrow, drops subscriptions) is right, so a human must decide.
ready_state
az_state BILLING_SUBS_acct-1 "sub-a|prof-1,sub-b|prof-2"
out="$TEST_TMP/out"
bash "$S" --tenant-id t1 --no-login >"$out" 2>/dev/null
r="$(row "$out" t1)"
assert_eq "$(field "$r" 8)" "unknown"
assert_eq "$(field "$r" 9)" "check"
printf '%s' "$r" | grep -q "span 2 billing profiles" || fail "note should say the profiles span"
teardown_test

setup_test "falls back to billingAccount when profiles cannot be read"
ready_state
az_state BILLING_SUBS_acct-1 ""
out="$TEST_TMP/out"
bash "$S" --tenant-id t1 --no-login >"$out" 2>/dev/null
r="$(row "$out" t1)"
assert_eq "$(field "$r" 7)" "-"
assert_eq "$(field "$r" 8)" "billingAccount"
teardown_test

setup_test "reports unknown, not 'no role', when the identity cannot be resolved"
# "I could not tell who I am" and "I am nobody here" must not look the same:
# the first needs a retry, the second needs a role grant.
ready_state
az_state SIGNED_IN_OID ""
az_state USER_NAME ""
out="$TEST_TMP/out"
bash "$S" --tenant-id t1 --no-login >"$out" 2>/dev/null
r="$(row "$out" t1)"
assert_eq "$(field "$r" 5)" "unknown"
assert_eq "$(field "$r" 9)" "check"
teardown_test

setup_test "blocks a tenant with no subscriptions"
ready_state
az_state SUBSCRIPTIONS_t1 ""
out="$TEST_TMP/out"
bash "$S" --tenant-id t1 --no-login >"$out" 2>/dev/null
r="$(row "$out" t1)"
assert_eq "$(field "$r" 4)" "0"
assert_eq "$(field "$r" 9)" "blocked"
teardown_test

setup_test "--no-login refuses a tenant that is not the active session"
az_state TENANT_ID "someone-else"
out="$TEST_TMP/out"
bash "$S" --tenant-id t1 --no-login >"$out" 2>/dev/null
r="$(row "$out" t1)"
assert_eq "$(field "$r" 9)" "blocked"
assert_az_not_called "login --tenant"
teardown_test

setup_test "signs in per tenant when --no-login is not given"
ready_state
bash "$S" --tenant-id t1 >/dev/null 2>&1
assert_az_not_called "login --tenant"   # already the active tenant
teardown_test

setup_test "signs in when the active tenant differs"
az_state TENANT_ID "t1"
az_state SIGNED_IN_OID "oid-1"; az_state MG_ROLES "Owner"
az_state BILLING_ACCOUNTS "acct-1"
bash "$S" --tenant-id t-other >/dev/null 2>&1
assert_az_called "login --tenant t-other"
teardown_test

setup_test "reads name,tenant-id pairs and skips blanks and comments"
ready_state
list="$TEST_TMP/tenants.txt"
printf '# a comment\n\nacme,t1\n' > "$list"
out="$TEST_TMP/out"
bash "$S" --tenants-file "$list" --no-login >"$out" 2>/dev/null
assert_eq "$(wc -l <"$out" | tr -d ' ')" "2"
assert_eq "$(field "$(row "$out" acme)" 2)" "t1"
teardown_test

setup_test "tolerates CRLF in a tenant list"
# A list exported from a spreadsheet carries \r, which would otherwise ride
# along inside the tenant id and fail every az call for reasons no message
# mentions.
ready_state
list="$TEST_TMP/tenants.txt"
printf 'acme,t1\r\n' > "$list"
out="$TEST_TMP/out"
bash "$S" --tenants-file "$list" --no-login >"$out" 2>/dev/null
assert_eq "$(field "$(row "$out" acme)" 2)" "t1"
teardown_test

setup_test "reads TENANT_ID out of existing tenant files"
ready_state
d="$TEST_TMP/tenants"; mkdir -p "$d"
printf 'TENANT_ID=t1\n' > "$d/acme.env"
printf 'TENANT_ID=\n'   > "$d/empty.env"
printf 'TENANT_ID=t9\n' > "$d/skipme.env.example"
out="$TEST_TMP/out"
bash "$S" --dir "$d" --no-login >"$out" 2>/dev/null
assert_eq "$(field "$(row "$out" acme)" 2)" "t1"
assert_eq "$(wc -l <"$out" | tr -d ' ')" "2"   # header + acme only
teardown_test

setup_test "requires exactly one input source"
if bash "$S" >/dev/null 2>"$TEST_TMP/err"; then fail "expected non-zero exit"; fi
assert_file_contains "$TEST_TMP/err" "exactly one"
if bash "$S" --tenant-id t1 --dir /tmp >/dev/null 2>"$TEST_TMP/err2"; then
  fail "expected non-zero exit for two sources"
fi
assert_file_contains "$TEST_TMP/err2" "exactly one"
teardown_test

setup_test "fails clearly on a missing tenants file"
if bash "$S" --tenants-file "$TEST_TMP/nope.txt" >/dev/null 2>"$TEST_TMP/err"; then
  fail "expected non-zero exit"
fi
assert_file_contains "$TEST_TMP/err" "no such file"
teardown_test

setup_test "exits 0 even when tenants are blocked"
# The survey succeeded; reporting a blocker is the job, not a failure. A
# caller that wants to gate reads the VERDICT column.
ready_state
az_state MG_ROLES "Reader"
bash "$S" --tenant-id t1 --no-login >/dev/null 2>&1
rc=$?
assert_eq "$rc" "0"
teardown_test

setup_test "creates nothing and never calls Kion"
ready_state
bash "$S" --tenant-id t1 --no-login >/dev/null 2>&1
assert_az_not_called "group create"
assert_az_not_called "storage account create"
assert_az_not_called "ad app create"
assert_az_not_called "role assignment create"
assert_az_not_called "rest --method put"
[ ! -s "$CURL_LOG" ] || fail "preflight must not call curl"
teardown_test

finish_tests
