#!/usr/bin/env bash
# Regression tests for hooks/pre-push-gate.sh.
#
# Each case runs the hook from a fixture package directory and asserts on the
# exit code (0 = allowed, 2 = blocked). Run: bash pre-push-gate.test.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="$SCRIPT_DIR/../hooks/pre-push-gate.sh"

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

# Fixture: package whose lint fails.
bad=$(mktemp -d)
printf '{"name":"bad","scripts":{"lint":"exit 1","test":"exit 0"}}' > "$bad/package.json"
touch "$bad/package-lock.json"

# Fixture: package whose scripts all pass.
good=$(mktemp -d)
printf '{"name":"good","scripts":{"lint":"exit 0","typecheck":"exit 0","test":"exit 0","build":"exit 0"}}' > "$good/package.json"
touch "$good/package-lock.json"

# Fixture: no package.json at all.
empty=$(mktemp -d)

run_case "push blocked when lint fails" 2 "$bad" 'git push origin feat/x'
run_case "push allowed when all scripts pass" 0 "$good" 'git push origin feat/x'
run_case "push allowed with no package.json" 0 "$empty" 'git push origin feat/x'
run_case "non-push command ignored" 0 "$bad" 'git status'

# Bypass env var must allow the push through.
jq -n --arg cmd 'git push' '{tool_input:{command:$cmd}}' \
  | (cd "$bad" && SKIP_PUSH_GATE=1 bash "$SUT") >/dev/null 2>&1
if [ $? -eq 0 ]; then
  echo "PASS: bypass env allows push (exit 0)"
  pass=$((pass + 1))
else
  echo "FAIL: bypass env allows push — expected exit 0"
  fail=$((fail + 1))
fi

rm -rf "$bad" "$good" "$empty"

echo ""
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
