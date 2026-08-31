#!/bin/bash
# Test harness: stub az/curl on PATH, record calls, assert on them.
HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_DIR="$(cd "$HARNESS_DIR/.." && pwd)"
TESTS_RUN=0; TESTS_FAILED=0; CURRENT_TEST=""

setup_test() {
  CURRENT_TEST="$1"; TESTS_RUN=$((TESTS_RUN+1)); TEST_FAILED=0
  TEST_TMP="$(mktemp -d)"
  export TEST_TMP AZ_LOG="$TEST_TMP/az.log" CURL_LOG="$TEST_TMP/curl.log" AZ_STATE="$TEST_TMP/az.state"
  : > "$AZ_LOG"; : > "$CURL_LOG"; : > "$AZ_STATE"
  mkdir -p "$TEST_TMP/bin"
  cp "$HARNESS_DIR/stubs/az" "$HARNESS_DIR/stubs/curl" "$TEST_TMP/bin/"
  chmod +x "$TEST_TMP/bin/az" "$TEST_TMP/bin/curl"
  export PATH="$TEST_TMP/bin:$PATH"
}

teardown_test() {
  if [ "$TEST_FAILED" -eq 0 ]; then echo "  ok   $CURRENT_TEST"
  else echo "  FAIL $CURRENT_TEST"; TESTS_FAILED=$((TESTS_FAILED+1)); fi
  rm -rf "$TEST_TMP"
}

az_state()  { echo "$1=$2" >> "$AZ_STATE"; }
fail()      { echo "       $*" >&2; TEST_FAILED=1; }
assert_eq() { [ "$1" = "$2" ] || fail "expected '$2', got '$1'"; }
assert_az_called()     { grep -qE -- "$1" "$AZ_LOG"   || fail "no az call matching: $1"; }
assert_az_not_called() { grep -qE -- "$1" "$AZ_LOG"   && fail "unexpected az call: $1"; return 0; }
assert_curl_called()   { grep -qE -- "$1" "$CURL_LOG" || fail "no curl call matching: $1"; }
assert_file_contains() { grep -qE -- "$2" "$1" || fail "$1 missing: $2"; }
finish_tests() { echo; echo "$TESTS_RUN run, $TESTS_FAILED failed"; [ "$TESTS_FAILED" -eq 0 ]; }
