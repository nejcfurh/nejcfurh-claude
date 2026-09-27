#!/usr/bin/env bash
# Regression tests for leak_scan in hooks/leak-patterns-lib.sh — the matcher
# the leak gates and the retro pre-flight share. Text passed as an argument
# and text piped on stdin must scan the same, because a pre-flight that pipes
# into a function reading only $1 scans an empty string and reports clean.
# Run: bash leak-patterns-lib.test.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

cd "$(mktemp -d "${TMPDIR:-/tmp}/hooktest-cwd.XXXXXX")" || exit 1

# shellcheck source=hooks/leak-patterns-lib.sh
. "$SCRIPT_DIR/../hooks/leak-patterns-lib.sh"

pass=0
fail=0
check() { # check <name> <expected> <actual>
  if [ "$2" = "$3" ]; then
    echo "PASS: $1"
    pass=$((pass + 1))
  else
    echo "FAIL: $1 (expected '$2', got '$3')"
    fail=$((fail + 1))
  fi
}

# Assembled at runtime so this file holds no literal ticket key for the commit gate to match.
dirty="fix the parser bug from $(printf 'AB%s' C)-1234"
clean="fix the parser bug"

check "a ticket key passed as an argument is found" " ticket-key" "$(leak_scan "$dirty")"
check "a ticket key piped on stdin is found" " ticket-key" "$(printf '%s\n' "$dirty" | leak_scan)"
check "clean text as an argument is clean" "" "$(leak_scan "$clean")"
check "clean text on stdin is clean" "" "$(printf '%s\n' "$clean" | leak_scan)"
check "an explicit empty argument does not read stdin" "" "$(printf '%s\n' "$dirty" | leak_scan "")"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
