#!/usr/bin/env bash
# Regression tests for hooks/pre-merge-gate.sh.
#
# Each case pipes a PreToolUse JSON payload into the hook and asserts on the
# exit code (0 = allowed, 2 = blocked). Run: bash pre-merge-gate.test.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="$SCRIPT_DIR/../hooks/pre-merge-gate.sh"

pass=0
fail=0

run_case() { # run_case <name> <expected-exit> <command-string>
  local name="$1" expected="$2" command="$3" got
  jq -n --arg cmd "$command" '{tool_input:{command:$cmd}}' \
    | bash "$SUT" >/dev/null 2>&1
  got=$?
  if [ "$got" = "$expected" ]; then
    echo "PASS: $name (exit $got)"
    pass=$((pass + 1))
  else
    echo "FAIL: $name — expected exit $expected, got $got"
    fail=$((fail + 1))
  fi
}

run_case "gh pr merge blocked" 2 \
  'gh pr merge 123 --squash'

run_case "merge buried in compound command blocked" 2 \
  'git push origin feat/x && gh pr merge 123 --squash --delete-branch'

run_case "gh api merge endpoint blocked" 2 \
  'gh api repos/owner/repo/pulls/5/merge -X PUT'

run_case "gh pr view allowed" 0 \
  'gh pr view 123'

run_case "gh pr create allowed" 0 \
  'gh pr create --title "feat: x" --body "y"'

run_case "gh api pulls read allowed" 0 \
  'gh api repos/owner/repo/pulls/5'

run_case "unrelated merge word allowed" 0 \
  'git merge --no-ff feat/x'

# Bypass env var must allow anything through.
jq -n --arg cmd 'gh pr merge 123' '{tool_input:{command:$cmd}}' \
  | SKIP_MERGE_GATE=1 bash "$SUT" >/dev/null 2>&1
if [ $? -eq 0 ]; then
  echo "PASS: bypass env allows merge (exit 0)"
  pass=$((pass + 1))
else
  echo "FAIL: bypass env allows merge — expected exit 0"
  fail=$((fail + 1))
fi

echo ""
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
