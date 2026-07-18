#!/usr/bin/env bash
# Regression tests for hooks/invalidate-verify-marker.sh.
#
# Any Write/Edit inside a repo must delete that repo's /verify-done marker;
# files elsewhere must leave it alone. Run: bash invalidate-verify-marker.test.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# A failed mktemp must never leak this suite's git commands into the real repo.
cd "$(mktemp -d "${TMPDIR:-/tmp}/hooktest-cwd.XXXXXX")" || exit 1
SUT="$SCRIPT_DIR/../hooks/invalidate-verify-marker.sh"

pass=0
fail=0

export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@test
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@test

check() { # check <name> <command…> — passes when the command exits 0
  local name="$1"
  shift
  if "$@"; then
    echo "PASS: $name"
    pass=$((pass + 1))
  else
    echo "FAIL: $name"
    fail=$((fail + 1))
  fi
}

repo=$(mktemp -d "${TMPDIR:-/tmp}/hooktest.XXXXXX")
other=$(mktemp -d "${TMPDIR:-/tmp}/hooktest.XXXXXX")
(cd "$repo" && git init -q -b feat/topic && git commit -q --allow-empty -m init)

# Edit inside the repo deletes the marker.
date > "$repo/.git/verify-done-ok"
jq -n --arg fp "$repo/src.ts" '{tool_input:{file_path:$fp}}' | bash "$SUT" >/dev/null 2>&1
check "edit inside repo deletes marker" [ ! -f "$repo/.git/verify-done-ok" ]

# Edit outside any repo leaves the marker alone.
date > "$repo/.git/verify-done-ok"
jq -n --arg fp "$other/note.md" '{tool_input:{file_path:$fp}}' | bash "$SUT" >/dev/null 2>&1
check "edit outside repo keeps marker" [ -f "$repo/.git/verify-done-ok" ]

# Payload without a file path is a no-op.
noop() { printf '%s' '{"tool_input":{}}' | bash "$SUT" >/dev/null 2>&1 && [ -f "$repo/.git/verify-done-ok" ]; }
check "missing file_path is a no-op" noop

rm -rf "$repo" "$other"

echo ""
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
