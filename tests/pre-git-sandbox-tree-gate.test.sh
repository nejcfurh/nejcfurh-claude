#!/usr/bin/env bash
# Regression tests for hooks/pre-git-sandbox-tree-gate.sh — blocks git commands
# that rewrite the working tree while the command sandbox is on (pull, merge,
# rebase, stash pop/apply, and checkout/switch of a ref) and leaves fetch,
# pathspec-scoped forms, read-only inspection and already-unsandboxed commands
# alone.
#
# The load-bearing case is "unsandboxed passes through": the gate tells the caller
# to retry with dangerouslyDisableSandbox, so if that retry were also blocked the
# gate would be a trap rather than a guard.
#
# The second load-bearing case is "trigger words as data": a commit message or a
# log grep mentioning pull/merge must not be blocked, or every retro about this
# very failure becomes unpushable.
# Run: bash pre-git-sandbox-tree-gate.test.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# A failed mktemp must never leak this suite's commands into the real repo.
cd "$(mktemp -d "${TMPDIR:-/tmp}/hooktest-cwd.XXXXXX")" || exit 1
SUT="$SCRIPT_DIR/../hooks/pre-git-sandbox-tree-gate.sh"

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

run_unsandboxed() { # run_unsandboxed <name> <expected-exit> <command-string>
  local name="$1" expected="$2" command="$3" got
  jq -n --arg cmd "$command" \
    '{tool_input:{command:$cmd,dangerouslyDisableSandbox:true}}' | bash "$SUT" >/dev/null 2>&1
  got=$?
  if [ "$got" = "$expected" ]; then
    echo "PASS: $name (exit $got)"
    pass=$((pass + 1))
  else
    echo "FAIL: $name — expected exit $expected, got $got"
    fail=$((fail + 1))
  fi
}

# --- blocked: merges into the working tree ------------------------------------
run_case "plain pull" 2 'git pull'
run_case "pull --ff-only with a remote and branch" 2 'git pull --ff-only origin main'
run_case "pull with -C prefix" 2 'git -C /tmp/repo pull'
run_case "pull after a cd" 2 'cd /tmp/repo && git pull --rebase'
run_case "merge a remote ref" 2 'git merge --ff-only origin/main'
run_case "merge a local branch" 2 'git merge feat/topic'
run_case "rebase onto a remote ref" 2 'git rebase origin/main'
run_case "rebase --continue" 2 'git rebase --continue'

# --- blocked: restoring a stash over the tree ---------------------------------
run_case "stash pop" 2 'git stash pop'
run_case "stash apply" 2 'git stash apply stash@{0}'

# --- blocked: ref checkout swaps the whole tree -------------------------------
run_case "checkout an existing branch" 2 'git checkout main'
run_case "switch an existing branch" 2 'git switch main'
run_case "checkout a detached commit" 2 'git checkout 1a2b3c4'

# --- allowed: the unsandboxed retry the gate asks for -------------------------
run_unsandboxed "pull unsandboxed" 0 'git pull --ff-only origin main'
run_unsandboxed "merge unsandboxed" 0 'git merge --ff-only origin/main'
run_unsandboxed "rebase unsandboxed" 0 'git rebase origin/main'
run_unsandboxed "checkout unsandboxed" 0 'git checkout main'
run_unsandboxed "stash pop unsandboxed" 0 'git stash pop'

# --- allowed: refs/objects only, no tree rewrite ------------------------------
run_case "fetch" 0 'git fetch origin main'
run_case "fetch --all --prune" 0 'git fetch --all --prune'
run_case "ls-remote" 0 'git ls-remote origin'

# --- allowed: pathspec-scoped and read-only forms -----------------------------
run_case "checkout -- pathspec restore" 0 'git checkout -- src/file.ts'
run_case "checkout ref -- pathspec" 0 'git checkout origin/main -- src/file.ts'
run_case "status" 0 'git status -sb'
run_case "log" 0 'git log --oneline -3'
run_case "diff against a remote ref" 0 'git diff origin/main --stat'
run_case "stash list" 0 'git stash list'
run_case "stash push is not a restore" 0 'git stash push -- src/file.ts'

# --- allowed: trigger words as DATA, not commands ----------------------------
run_case "commit message mentioning pull" 0 'git commit -m "docs: explain why git pull is gated"'
run_case "commit message mentioning merge" 0 'git commit -m "chore: stop running git merge by hand"'
run_case "grep for a pull" 0 'git log --grep="git pull"'
run_case "non-git command containing the words" 0 'echo "git pull origin main"'

# --- bypass -------------------------------------------------------------------
SKIP_GIT_SANDBOX_TREE_GATE=1 run_case "SKIP env bypasses the gate" 0 'git pull --ff-only origin main'

echo
echo "passed: $pass, failed: $fail"
[ "$fail" -eq 0 ] || exit 1
