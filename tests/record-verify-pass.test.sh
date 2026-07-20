#!/usr/bin/env bash
# Regression tests for scripts/record-verify-pass.sh.
#
# The push-trusted marker may only be minted for a clean tracked tree — a
# pass on a dirty tree certifies content a push would not publish. Untracked
# files never reach the pushed commit and must not block the marker.
# Run: bash record-verify-pass.test.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# A failed mktemp must never leak this suite's git commands into the real repo.
cd "$(mktemp -d "${TMPDIR:-/tmp}/hooktest-cwd.XXXXXX")" || exit 1
SUT="$SCRIPT_DIR/../scripts/record-verify-pass.sh"

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
(cd "$repo" && git init -q -b feat/topic \
  && echo "line1" > tracked.txt && git add tracked.txt \
  && git commit -q -m "feat: init")
marker="$repo/.git/verify-done-ok"

# Clean tree: marker written, first line is HEAD.
clean_writes() {
  (cd "$repo" && bash "$SUT" >/dev/null 2>&1) \
    && [ -f "$marker" ] \
    && [ "$(head -n1 "$marker")" = "$(git -C "$repo" rev-parse HEAD)" ]
}
check "clean tree writes marker bound to HEAD" clean_writes

# Modified tracked file: refused, and any existing marker is left untouched
# (invalidate-verify-marker / HEAD binding handle staleness — this script
# only decides whether to MINT).
dirty_refuses() {
  echo "line2" >> "$repo/tracked.txt"
  ! (cd "$repo" && bash "$SUT" >/dev/null 2>&1)
}
check "dirty tracked tree refuses to write" dirty_refuses

refusal_names_verdict() {
  (cd "$repo" && bash "$SUT" 2>&1 >/dev/null || true) | grep -q "READY TO COMMIT"
}
check "refusal message names READY TO COMMIT" refusal_names_verdict

# Staged-but-uncommitted change: refused.
staged_refuses() {
  (cd "$repo" && git add tracked.txt)
  ! (cd "$repo" && bash "$SUT" >/dev/null 2>&1)
}
check "staged change refuses to write" staged_refuses

# Committing the change makes minting legal again, with the new HEAD.
commit_reenables() {
  (cd "$repo" && git commit -q -m "feat: change") || return 1
  (cd "$repo" && bash "$SUT" >/dev/null 2>&1) \
    && [ "$(head -n1 "$marker")" = "$(git -C "$repo" rev-parse HEAD)" ]
}
check "post-commit run records the new HEAD" commit_reenables

# Untracked files do not block: they never alter the pushed commit.
untracked_ok() {
  rm -f "$marker"
  echo "scratch" > "$repo/notes.txt"
  (cd "$repo" && bash "$SUT" >/dev/null 2>&1) && [ -f "$marker" ]
}
check "untracked file does not block the marker" untracked_ok

# Outside a repository: error exit, nothing created.
outside_fails() {
  ! (cd "$other" && bash "$SUT" >/dev/null 2>&1)
}
check "outside a repo exits non-zero" outside_fails

rm -rf "$repo" "$other"

echo ""
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
