#!/usr/bin/env bash
# Regression tests for hooks/pre-edit-branch-drift-gate.sh — warns (never blocks)
# when the branch under an edit is not the one this session last edited there.
#
# The load-bearing case is SILENCE. Every edit in a session runs this, so a gate
# that speaks on the first edit, on an unchanged branch, or outside a repository
# is noise nobody reads. Only an actual change between two edits is worth a word.
#
# Exit code is always 0: a branch change is frequently deliberate.
# Run: bash pre-edit-branch-drift-gate.test.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="$SCRIPT_DIR/../hooks/pre-edit-branch-drift-gate.sh"

work=$(mktemp -d "${TMPDIR:-/tmp}/hooktest-branchdrift.XXXXXX") || exit 1
export EDIT_BRANCH_STATE_DIR="$work/state"
trap 'rm -rf "$work"' EXIT

pass=0
fail=0

# is_context <output> — true when the hook spoke in the JSON envelope Claude
# Code feeds to the model. Plain stdout from a PreToolUse hook that exits 0 is
# shown only in the transcript, so a warning printed that way never reaches the
# model; "some output" is not enough to count as firing.
is_context() {
  printf '%s' "$1" | jq -e \
    '.hookSpecificOutput.hookEventName == "PreToolUse" and (.hookSpecificOutput.additionalContext | length > 0)' \
    >/dev/null 2>&1
}

# edit <session> <file> — runs the gate as one Write/Edit call, echoes its output
edit() {
  jq -n --arg s "$1" --arg f "$2" '{session_id:$s, tool_input:{file_path:$f}}' \
    | bash "$SUT" 2>/dev/null
}

check() {
  local name="$1" expected="$2" out="$3" rc="$4"
  local got="quiet"
  [ -n "$out" ] && got="fires"
  [ "$got" = "fires" ] && ! is_context "$out" && got="plain text the model never sees"
  if [ "$got" = "$expected" ] && [ "$rc" = "0" ]; then
    echo "PASS: $expected — $name"
    pass=$((pass + 1))
  else
    echo "FAIL: $expected — $name (got $got, exit $rc)"
    fail=$((fail + 1))
  fi
}

repo="$work/repo"
mkdir -p "$repo"
git -C "$repo" init -q 2>/dev/null
git -C "$repo" config user.email t@example.com
git -C "$repo" config user.name t
git -C "$repo" checkout -q -b main 2>/dev/null
echo x > "$repo/a.ts"
git -C "$repo" add a.ts
git -C "$repo" commit -qm "init" 2>/dev/null

# --- quiet: nothing to compare against yet -----------------------------------
out=$(edit s1 "$repo/a.ts"); check "first edit in a repo" quiet "$out" $?

# --- quiet: same branch, later edits -----------------------------------------
out=$(edit s1 "$repo/a.ts"); check "second edit, branch unchanged" quiet "$out" $?

# --- fires: the branch moved under the session -------------------------------
git -C "$repo" checkout -q -b other 2>/dev/null
out=$(edit s1 "$repo/a.ts"); check "branch changed between edits" fires "$out" $?

# The warning names both branches, so the reader can tell which way it moved.
case "$out" in
  *main*other*) echo "PASS: names both branches"; pass=$((pass + 1)) ;;
  *) echo "FAIL: names both branches (got: $out)"; fail=$((fail + 1)) ;;
esac

# --- quiet: having reported once, the new branch is the baseline -------------
out=$(edit s1 "$repo/a.ts"); check "settles after reporting" quiet "$out" $?

# --- quiet: a different session has its own baseline -------------------------
out=$(edit s2 "$repo/a.ts"); check "other session, first edit" quiet "$out" $?

# --- quiet: a second worktree is its own tree, not a branch change -----------
# Worktrees of one repository sit on different branches by design, so keying on
# the working tree rather than the git dir keeps them independent.
wt="$work/wt"
git -C "$repo" worktree add -q -b wtbranch "$wt" 2>/dev/null
if [ -d "$wt" ]; then
  out=$(edit s1 "$wt/a.ts"); check "first edit in a sibling worktree" quiet "$out" $?
else
  echo "SKIP: worktree case (git worktree unavailable)"
fi

# --- quiet: outside a repository ---------------------------------------------
mkdir -p "$work/plain"
echo x > "$work/plain/a.ts"
out=$(edit s1 "$work/plain/a.ts"); check "file outside any repo" quiet "$out" $?

# --- quiet: malformed and empty payloads -------------------------------------
out=$(printf 'not json' | bash "$SUT" 2>/dev/null); check "non-JSON payload" quiet "$out" $?
out=$(printf '' | bash "$SUT" 2>/dev/null); check "empty payload" quiet "$out" $?
out=$(jq -n '{tool_input:{file_path:"/nope/a.ts"}}' | bash "$SUT" 2>/dev/null)
check "payload without a session id" quiet "$out" $?

# --- quiet: the bypass --------------------------------------------------------
git -C "$repo" checkout -q main 2>/dev/null
out=$(SKIP_EDIT_BRANCH_DRIFT_GATE=1 edit s1 "$repo/a.ts")
check "SKIP env silences the gate" quiet "$out" $?

echo
echo "passed: $pass, failed: $fail"
[ "$fail" -eq 0 ] || exit 1
