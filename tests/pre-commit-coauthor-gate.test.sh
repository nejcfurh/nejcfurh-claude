#!/usr/bin/env bash
# Regression tests for hooks/pre-commit-coauthor-gate.sh.
# Run: bash pre-commit-coauthor-gate.test.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# A failed mktemp must never leak this suite's git commands into the real repo.
cd "$(mktemp -d "${TMPDIR:-/tmp}/hooktest-cwd.XXXXXX")" || exit 1
SUT="$SCRIPT_DIR/../hooks/pre-commit-coauthor-gate.sh"

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

run_case "co-authored-by footer blocked" 2 \
  'git commit -m "feat: x

Co-Authored-By: Someone <noreply@example.com>"'

run_case "generated-with footer blocked (case-insensitive)" 2 \
  'git commit -m "feat: x

🤖 generated with claude"'

run_case "clean message allowed" 0 \
  'git commit -m "feat(auth): add login"'

run_case "non-commit command ignored" 0 \
  'echo "Co-Authored-By in a random echo"'

run_case "git -C form with attribution blocked" 2 \
  'git -C /some/repo commit -m "feat: x

Co-Authored-By: Someone <noreply@example.com>"'

# Bypass env var must allow anything through.
jq -n --arg cmd 'git commit -m "x Co-Authored-By: y"' '{tool_input:{command:$cmd}}' \
  | SKIP_COAUTHOR_GATE=1 bash "$SUT" >/dev/null 2>&1
if [ $? -eq 0 ]; then
  echo "PASS: bypass env allows anything (exit 0)"
  pass=$((pass + 1))
else
  echo "FAIL: bypass env allows anything — expected exit 0"
  fail=$((fail + 1))
fi

echo ""
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
