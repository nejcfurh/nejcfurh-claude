#!/usr/bin/env bash
# Regression tests for hooks/pre-git-sandbox-config-gate.sh — blocks git commands
# that write .git/config while the command sandbox is on (checkout -b, switch -c,
# branch delete/move/upstream, push -u, config writes, remote mutations) and
# leaves read-only forms and already-unsandboxed commands alone.
#
# The load-bearing case is "unsandboxed passes through": the gate tells the caller
# to retry with dangerouslyDisableSandbox, so if that retry were also blocked the
# gate would be a trap rather than a guard.
# Run: bash pre-git-sandbox-config-gate.test.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# A failed mktemp must never leak this suite's commands into the real repo.
cd "$(mktemp -d "${TMPDIR:-/tmp}/hooktest-cwd.XXXXXX")" || exit 1
SUT="$SCRIPT_DIR/../hooks/pre-git-sandbox-config-gate.sh"

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

# --- blocked: branch creation with tracking -----------------------------------
run_case "checkout -b off a remote ref" 2 'git checkout -b feat/topic origin/main'
run_case "checkout -B" 2 'git checkout -B feat/topic origin/main'
run_case "switch -c" 2 'git switch -c feat/topic origin/main'
run_case "checkout -b with -C prefix" 2 'git -C /tmp/repo checkout -b feat/topic origin/main'
run_case "checkout -b after a cd" 2 'cd /tmp/repo && git checkout -b feat/topic origin/main'

# --- blocked: branch config mutations ----------------------------------------
run_case "branch -d" 2 'git branch -d feat/topic'
run_case "branch -D" 2 'git branch -D feat/topic'
run_case "branch --delete" 2 'git branch --delete feat/topic'
run_case "branch -m rename" 2 'git branch -m old new'
run_case "branch --unset-upstream" 2 'git branch --unset-upstream'
run_case "branch --set-upstream-to=" 2 'git branch --set-upstream-to=origin/main'
run_case "several branches deleted at once" 2 'git branch -d one two three'

# --- blocked: push tracking write --------------------------------------------
run_case "push -u" 2 'git push -u origin feat/topic'
run_case "push --set-upstream" 2 'git push --set-upstream origin feat/topic'

# --- blocked: config writes ---------------------------------------------------
run_case "config bare assignment" 2 'git config user.name Someone'
run_case "config --add" 2 'git config --add remote.origin.fetch +refs/heads/*:refs/remotes/origin/*'
run_case "config --unset" 2 'git config --unset branch.feat/topic.remote'
run_case "config --remove-section" 2 'git config --remove-section branch.feat/topic'

# --- blocked: remote mutations ------------------------------------------------
run_case "remote add" 2 'git remote add upstream https://example.com/r.git'
run_case "remote set-url" 2 'git remote set-url origin https://example.com/r.git'
run_case "remote rm" 2 'git remote rm upstream'

# --- allowed: the unsandboxed retry the gate asks for -------------------------
run_unsandboxed "checkout -b unsandboxed" 0 'git checkout -b feat/topic origin/main'
run_unsandboxed "branch -d unsandboxed" 0 'git branch -d feat/topic'
run_unsandboxed "push -u unsandboxed" 0 'git push -u origin feat/topic'
run_unsandboxed "config write unsandboxed" 0 'git config --remove-section branch.feat/topic'

# --- allowed: read-only and non-config forms ---------------------------------
run_case "plain checkout of an existing branch" 0 'git checkout main'
run_case "checkout -- pathspec restore" 0 'git checkout -- src/file.ts'
run_case "plain switch" 0 'git switch main'
run_case "branch listing" 0 'git branch -vv'
run_case "branch --merged" 0 'git branch --merged origin/main'
run_case "branch --list glob" 0 'git branch --list feat/*'
run_case "plain push" 0 'git push'
run_case "push with a refspec" 0 'git push origin feat/topic'
run_case "push --force-with-lease" 0 'git push --force-with-lease'
run_case "config --get" 0 'git config --get user.name'
run_case "config --get-regexp" 0 'git config --get-regexp ^branch\.'
run_case "config --list" 0 'git config --list'
run_case "config --get with --file" 0 'git config --file /tmp/cfg --get user.name'
run_case "remote -v" 0 'git remote -v'
run_case "remote get-url" 0 'git remote get-url origin'
run_case "plain remote" 0 'git remote'
run_case "status" 0 'git status --porcelain'
run_case "commit" 0 'git commit -m "feat: add a thing"'
run_case "log" 0 'git log --oneline -5'
run_case "fetch --prune" 0 'git fetch origin --prune'
run_case "stash push" 0 'git stash push -- src/file.ts'

# --- allowed: trigger words as DATA, not commands ----------------------------
run_case "commit message mentioning checkout -b" 0 'git commit -m "docs: explain git checkout -b"'
run_case "commit message mentioning branch -d" 0 'git commit -m "chore: stop running git branch -d by hand"'
run_case "grep for a config write" 0 'git log --grep="git config --add"'
run_case "non-git command containing the words" 0 'echo "git push -u origin main"'

# --- bypass -------------------------------------------------------------------
SKIP_GIT_SANDBOX_CONFIG_GATE=1 run_case "SKIP env bypasses the gate" 0 'git checkout -b feat/topic origin/main'

echo
echo "passed: $pass, failed: $fail"
[ "$fail" -eq 0 ] || exit 1
