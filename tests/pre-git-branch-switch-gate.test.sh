#!/usr/bin/env bash
# Regression tests for hooks/pre-git-branch-switch-gate.sh — blocks moving a
# checkout onto an existing branch while tracked files are modified, because git
# silently carries those changes across and reports success.
#
# The load-bearing cases are the ALLOWs: `-b`/`-c` and path restores are the
# everyday forms, and a gate that caught them would be friction on every branch
# someone starts. The block itself only needs to fire on the one shape that
# takes over a working tree.
# Run: bash pre-git-branch-switch-gate.test.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="$SCRIPT_DIR/../hooks/pre-git-branch-switch-gate.sh"

# A failed mktemp must never leak this suite's commands into the real repo.
FIXTURE="$(mktemp -d "${TMPDIR:-/tmp}/hooktest-branchswitch.XXXXXX")" || exit 1
cd "$FIXTURE" || exit 1

git init -q -b main . >/dev/null 2>&1
git config user.email t@example.com
git config user.name Test
echo one > tracked.txt
echo two > other.txt
git add -A >/dev/null 2>&1
git commit -qm init >/dev/null 2>&1
git branch feature >/dev/null 2>&1

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

make_dirty() { echo changed >> tracked.txt; }
make_clean() { git checkout -q -- tracked.txt 2>/dev/null; git clean -qfd >/dev/null 2>&1; }

# --- clean tree: nothing to carry, every form allowed ---
make_clean
run_case "checkout existing branch, clean tree" 0 "git checkout feature"
run_case "switch existing branch, clean tree" 0 "git switch feature"

# --- dirty tracked tree: the takeover shape ---
make_dirty
run_case "checkout existing branch, dirty tree" 2 "git checkout feature"
run_case "switch existing branch, dirty tree" 2 "git switch feature"
run_case "checkout with -C targeting the repo, dirty tree" 2 "git -C $FIXTURE checkout feature"

# --- dirty tree, but forms that are not a takeover ---
run_case "checkout -b starts a branch with your work" 0 "git checkout -b newbranch"
run_case "checkout -B starts a branch with your work" 0 "git checkout -B newbranch"
run_case "switch -c starts a branch with your work" 0 "git switch -c newbranch"
run_case "explicit path restore" 0 "git checkout -- tracked.txt"
run_case "bareword path restore" 0 "git checkout tracked.txt"
run_case "detach is not a branch takeover" 0 "git checkout --detach feature"
run_case "already on this branch" 0 "git checkout main"
run_case "unresolvable ref is git's error to report" 0 "git checkout no-such-branch"
run_case "unrelated git command" 0 "git status"
run_case "non-git command naming a branch" 0 "echo git checkout feature"

# --- untracked files are not carried across ---
make_clean
echo scratch > untracked.txt
run_case "untracked-only tree is not a takeover" 0 "git checkout feature"
rm -f untracked.txt

# --- bypass ---
make_dirty
got_bypass=$(SKIP_GIT_BRANCH_SWITCH_GATE=1 jq -n --arg cmd "git checkout feature" \
  '{tool_input:{command:$cmd}}' | SKIP_GIT_BRANCH_SWITCH_GATE=1 bash "$SUT" >/dev/null 2>&1; echo $?)
if [ "$got_bypass" = "0" ]; then
  echo "PASS: SKIP_GIT_BRANCH_SWITCH_GATE bypasses (exit 0)"
  pass=$((pass + 1))
else
  echo "FAIL: SKIP_GIT_BRANCH_SWITCH_GATE bypasses — expected 0, got $got_bypass"
  fail=$((fail + 1))
fi

# --- the block names what is at risk, so the message is actionable ---
msg=$(jq -n --arg cmd "git checkout feature" '{tool_input:{command:$cmd}}' | bash "$SUT" 2>&1 >/dev/null)
if printf '%s' "$msg" | grep -q 'tracked.txt' && printf '%s' "$msg" | grep -q 'worktree'; then
  echo "PASS: block lists the modified files and points at a worktree"
  pass=$((pass + 1))
else
  echo "FAIL: block message missing the file list or the worktree fix"
  fail=$((fail + 1))
fi

cd / || exit 1
rm -rf "$FIXTURE"

echo ""
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
