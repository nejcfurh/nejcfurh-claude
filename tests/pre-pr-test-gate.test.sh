#!/usr/bin/env bash
# Regression tests for hooks/pre-pr-test-gate.sh.
# Run: bash pre-pr-test-gate.test.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="$SCRIPT_DIR/../hooks/pre-pr-test-gate.sh"

pass=0
fail=0

unset CLAUDE_PROJECT_DIR

run_case() { # run_case <name> <expected-exit> <cwd> <command-string>
  local name="$1" expected="$2" cwd="$3" command="$4" got
  jq -n --arg cmd "$command" '{tool_input:{command:$cmd}}' \
    | (cd "$cwd" && bash "$SUT") >/dev/null 2>&1
  got=$?
  if [ "$got" = "$expected" ]; then
    echo "PASS: $name (exit $got)"
    pass=$((pass + 1))
  else
    echo "FAIL: $name — expected exit $expected, got $got"
    fail=$((fail + 1))
  fi
}

failing=$(mktemp -d)
printf '{"name":"failing","scripts":{"test":"exit 1"}}' > "$failing/package.json"
touch "$failing/package-lock.json"

passing=$(mktemp -d)
printf '{"name":"passing","scripts":{"test":"exit 0"}}' > "$passing/package.json"
touch "$passing/package-lock.json"

placeholder=$(mktemp -d)
printf '{"name":"placeholder","scripts":{"test":"echo \\"Error: no test specified\\" && exit 1"}}' > "$placeholder/package.json"

run_case "PR blocked when tests fail" 2 "$failing" 'gh pr create --fill'
run_case "PR allowed when tests pass" 0 "$passing" 'gh pr create --fill'
run_case "npm placeholder test script not gated" 0 "$placeholder" 'gh pr create --fill'
run_case "non-PR command ignored" 0 "$failing" 'gh pr view'

# Bypass env var must allow the PR through.
jq -n --arg cmd 'gh pr create' '{tool_input:{command:$cmd}}' \
  | (cd "$failing" && SKIP_PR_TEST_GATE=1 bash "$SUT") >/dev/null 2>&1
if [ $? -eq 0 ]; then
  echo "PASS: bypass env allows PR (exit 0)"
  pass=$((pass + 1))
else
  echo "FAIL: bypass env allows PR — expected exit 0"
  fail=$((fail + 1))
fi

rm -rf "$failing" "$passing" "$placeholder"

echo ""
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
