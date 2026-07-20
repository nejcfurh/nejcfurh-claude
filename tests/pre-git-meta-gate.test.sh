#!/usr/bin/env bash
# Regression tests for hooks/pre-git-meta-gate.sh — blocks git meta-execution
# surfaces (git-level -c / --config-env / --exec-path config injection, and
# diff --no-index arbitrary-file reads) while leaving legit forms alone
# (git commit -c/-C reuse-message, git -C <path>, trigger words in quoted data).
# Run: bash pre-git-meta-gate.test.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# A failed mktemp must never leak this suite's commands into the real repo.
cd "$(mktemp -d "${TMPDIR:-/tmp}/hooktest-cwd.XXXXXX")" || exit 1
SUT="$SCRIPT_DIR/../hooks/pre-git-meta-gate.sh"

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

# --- blocked: git-level config injection --------------------------------------
run_case "git -c core.pager injection" 2 'git -c core.pager=/bin/sh log'
run_case "git -c alias injection" 2 'git -c alias.p=checkout status'
run_case "git -c core.hooksPath injection" 2 'git -c core.hooksPath=/tmp commit -m x'
run_case "git --config-env injection" 2 'git --config-env=core.pager=EVIL log'
run_case "git --exec-path binary hijack" 2 'git --exec-path=/tmp/evil status'
run_case "-c still caught after -C <path>" 2 'git -C /tmp -c core.pager=x log'
run_case "-c in a compound (cd && git)" 2 'cd /tmp && git -c core.pager=x log'
run_case "-c after an env-var prefix" 2 'GIT_TRACE=1 git -c core.pager=x log'
run_case "-c before a push" 2 'git -c core.pager=x push origin feat/topic'

# --- blocked: diff --no-index arbitrary-file read -----------------------------
run_case "git diff --no-index reads outside repo" 2 'git diff --no-index /dev/null /etc/hosts'
run_case "no-index with -C prefix" 2 'git -C /tmp diff --no-index /dev/null /etc/hosts'

# --- allowed: legit forms that merely resemble the blocked ones ---------------
run_case "plain status" 0 'git status'
run_case "conventional commit" 0 'git commit -m "feat: add thing"'
run_case "commit-level -c reuses a message" 0 'git commit -c HEAD'
run_case "commit-level -C reuses a message" 0 'git commit -C HEAD~1'
run_case "-C <path> change-dir" 0 'git -C /tmp status'
run_case "--no-pager global flag" 0 'git --no-pager log'
run_case "normal push" 0 'git push origin feat/topic'
run_case "branch -c copy (post-subcommand -c)" 0 'git branch -c old new'
run_case "plain diff" 0 'git diff HEAD~1'

# --- allowed: trigger words as DATA must not trip the gate --------------------
run_case "-c inside a quoted commit message" 0 'git commit -m "refactor: drop git -c hacks"'
run_case "--no-index inside a quoted --grep" 0 'git log --grep="the git diff --no-index trick"'
run_case "trigger words in a non-git command" 0 'echo "git -c core.pager=evil"'

# --- bypass -------------------------------------------------------------------
jq -n --arg cmd 'git -c core.pager=x log' '{tool_input:{command:$cmd}}' \
  | SKIP_GIT_META_GATE=1 bash "$SUT" >/dev/null 2>&1
if [ $? -eq 0 ]; then
  echo "PASS: SKIP_GIT_META_GATE bypasses (exit 0)"
  pass=$((pass + 1))
else
  echo "FAIL: SKIP_GIT_META_GATE bypass — expected exit 0"
  fail=$((fail + 1))
fi

echo ""
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
