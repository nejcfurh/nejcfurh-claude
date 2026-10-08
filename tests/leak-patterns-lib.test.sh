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

# A guarded repo is itself in the project list, so its own name and owner are derived
# terms too. --repo excludes that identity without unprotecting any other project.
FIXTURE="$(mktemp -d "${TMPDIR:-/tmp}/leaklib.XXXXXX")" || exit 1
trap 'rm -rf "$FIXTURE"' EXIT
export CLAUDE_LEAK_PATTERNS="$FIXTURE/no-patterns"
export CLAUDE_PROJECTS_DIR="$FIXTURE/projects"
mkdir -p "$CLAUDE_PROJECTS_DIR/-Users-x-Projects-selfowner-selfrepo" \
  "$CLAUDE_PROJECTS_DIR/-Users-x-Projects-selfdir" \
  "$CLAUDE_PROJECTS_DIR/-Users-x-Projects-otherclient-portal" \
  "$CLAUDE_PROJECTS_DIR/-Users-x-Projects-wtname"
SELF="$FIXTURE/selfdir"
git init -q "$SELF" 2>/dev/null || exit 1
git -C "$SELF" remote add origin git@github.com:selfowner/selfrepo.git
git -C "$SELF" -c user.email=t@example.com -c user.name=T commit -q --allow-empty -m seed
git -C "$SELF" worktree add -q "$FIXTURE/wtname" 2>/dev/null || exit 1

own='"repo": "selfowner/selfrepo"'
check "the repo's own name is a hit when no repo is named" " project-name" "$(leak_scan "$own")"
check "the repo's own origin owner and name pass with --repo" "" "$(leak_scan --repo "$SELF" "$own")"
check "the repo's own checkout folder name passes with --repo" "" "$(leak_scan --repo "$SELF" "the selfdir checkout")"
check "--repo works on stdin" "" "$(printf '%s\n' "$own" | leak_scan --repo "$SELF")"
check "another project's name still blocks with --repo" " project-name" "$(leak_scan --repo "$SELF" "work for otherclient")"
check "a worktree resolves to the main checkout's identity" "" "$(leak_scan --repo "$FIXTURE/wtname" "selfdir selfowner selfrepo")"
check "a worktree's own folder name is not excluded" " project-name" "$(leak_scan --repo "$FIXTURE/wtname" "the wtname branch")"
check "an https origin is parsed the same way" "" "$(git -C "$SELF" remote set-url origin https://github.com/selfowner/selfrepo.git && leak_scan --repo "$SELF" "$own")"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
