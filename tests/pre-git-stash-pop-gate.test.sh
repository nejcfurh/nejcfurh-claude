#!/usr/bin/env bash
# Regression tests for hooks/pre-git-stash-pop-gate.sh — blocks `git stash pop`
# and `git stash apply` that name no entry, because the implicit target is
# whatever is newest on a list that outlives the session.
#
# The load-bearing cases are the ALLOWs. Naming an entry is the deliberate act
# the gate is asking for, an empty list has nothing to take, and every other
# stash subcommand is untouched — a gate that caught `git stash push` would be
# friction on the ordinary way work gets set aside.
# Run: bash pre-git-stash-pop-gate.test.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="$SCRIPT_DIR/../hooks/pre-git-stash-pop-gate.sh"

# A failed mktemp must never leak this suite's commands into the real repo.
FIXTURE="$(mktemp -d "${TMPDIR:-/tmp}/hooktest-stashpop.XXXXXX")" || exit 1
cd "$FIXTURE" || exit 1

git init -q -b main . >/dev/null 2>&1
git config user.email t@example.com
git config user.name Test
echo one > tracked.txt
git add -A >/dev/null 2>&1
git commit -qm init >/dev/null 2>&1

pass=0
fail=0

run_case() { # run_case <name> <expected-exit> <command-string>
  local name="$1" expected="$2" command="$3" got
  jq -n --arg cmd "$command" '{tool_input:{command:$cmd}}' | bash "$SUT" >/dev/null 2>&1
  got=$?
  if [ "$got" = "$expected" ]; then
    echo "PASS: $name (exit $got)"
    pass=$((pass + 1))
  else
    echo "FAIL: $name — expected exit $expected, got $got"
    fail=$((fail + 1))
  fi
}

# --- an empty stash list has nothing to take, so nothing is gated ---
run_case "pop with an empty stash list" 0 "git stash pop"
run_case "apply with an empty stash list" 0 "git stash apply"

# Put something on the stack — from here the implicit target exists.
echo changed > tracked.txt
git stash push -q -m "someone else's work" >/dev/null 2>&1

# --- the shape that takes the top of a shared stack ---
run_case "bare pop" 2 "git stash pop"
run_case "bare apply" 2 "git stash apply"
run_case "pop with only flags" 2 "git stash pop --index"
run_case "pop reached through -C" 2 "git -C $FIXTURE stash pop"
run_case "pop after a cd" 2 "cd $FIXTURE && git stash pop"

# --- naming the entry is the deliberate act the gate wants ---
run_case "pop names an entry" 0 "git stash pop 'stash@{0}'"
run_case "apply names an entry" 0 "git stash apply 'stash@{1}'"
run_case "pop names an entry after a flag" 0 "git stash pop --index 'stash@{0}'"

# --- every other stash subcommand is somebody setting work aside ---
run_case "push" 0 "git stash push -- some/path.ts"
run_case "bare stash is a push" 0 "git stash"
run_case "list" 0 "git stash list"
run_case "show" 0 "git stash show"
run_case "drop" 0 "git stash drop"
run_case "clear" 0 "git stash clear"
run_case "branch" 0 "git stash branch recovered"

# --- unrelated git commands never reach it ---
run_case "an unrelated commit" 0 "git commit -m 'pop the stash'"

# --- the bypass works ---
got_bypass=$(jq -n --arg cmd "git stash pop" \
  '{tool_input:{command:$cmd}}' | SKIP_GIT_STASH_POP_GATE=1 bash "$SUT" >/dev/null 2>&1; echo $?)
if [ "$got_bypass" = "0" ]; then
  echo "PASS: SKIP_GIT_STASH_POP_GATE bypasses (exit 0)"
  pass=$((pass + 1))
else
  echo "FAIL: SKIP_GIT_STASH_POP_GATE bypasses — expected 0, got $got_bypass"
  fail=$((fail + 1))
fi

# --- the block shows what is on the stack and how to name it ---
msg=$(jq -n --arg cmd "git stash pop" '{tool_input:{command:$cmd}}' | bash "$SUT" 2>&1 >/dev/null)
if printf '%s' "$msg" | grep -q "someone else's work" && printf '%s' "$msg" | grep -q 'stash@{0}'; then
  echo "PASS: block lists the stash entries and shows how to name one"
  pass=$((pass + 1))
else
  echo "FAIL: block message missing the stash list or the explicit-entry fix"
  fail=$((fail + 1))
fi

cd / || exit 1
rm -rf "$FIXTURE"

echo ""
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
