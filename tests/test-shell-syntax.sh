#!/bin/bash
#
# The design spec's §Testing requires "bash -n on every script and shellcheck
# where available". Neither was wired into anything, so a script could ship
# with a syntax error that no stub test happened to reach. This runs both as
# part of `make test`.
set -uo pipefail
. "$(dirname "$0")/lib/harness.sh"

# Every shell script the tool actually runs, plus the test harness and stubs
# the suite itself depends on. Bash 3.2: no mapfile, so read the find output
# with a while loop.
SHELL_FILES=()
while IFS= read -r f; do
  [ -n "$f" ] && SHELL_FILES+=("$f")
done < <(find "$REPO_DIR/scripts" "$REPO_DIR/tests" -type f -name '*.sh' | sort)
SHELL_FILES+=("$REPO_DIR/tests/stubs/az" "$REPO_DIR/tests/stubs/curl")

setup_test "every shell script parses under bash -n"
for f in ${SHELL_FILES[@]+"${SHELL_FILES[@]}"}; do
  bash -n "$f" 2>"$TEST_TMP/syntax.err" \
    || fail "bash -n failed on ${f#"$REPO_DIR/"}: $(cat "$TEST_TMP/syntax.err")"
done
teardown_test

if command -v shellcheck >/dev/null 2>&1; then
  setup_test "shellcheck -S warning is clean on every shell script"
  # -S warning: style/info notes are advisory and would make this test a
  # constant nuisance; warnings and errors are real defects.
  # -x so sourced lib/common.sh is followed rather than reported as unreadable.
  if ! shellcheck -S warning -x ${SHELL_FILES[@]+"${SHELL_FILES[@]}"} >"$TEST_TMP/sc.out" 2>&1; then
    fail "shellcheck reported warnings or errors:"
    sed "s|$REPO_DIR/||" "$TEST_TMP/sc.out" >&2
  fi
  teardown_test
else
  echo "  skip shellcheck (not on PATH)"
fi

finish_tests
