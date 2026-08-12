#!/usr/bin/env bash
# Regression tests for hooks/pre-push-marker-chain-gate.sh.
#
# Each case pipes a PreToolUse JSON payload into the hook and asserts on the
# exit code (0 = allowed, 2 = blocked). The gate exists because a marker
# recorded in the same command cannot exist when the push gate reads it.
# Run: bash pre-push-marker-chain-gate.test.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

cd "$(mktemp -d "${TMPDIR:-/tmp}/hooktest-cwd.XXXXXX")" || exit 1
SUT="$SCRIPT_DIR/../hooks/pre-push-marker-chain-gate.sh"

pass=0
fail=0

unset SKIP_MARKER_CHAIN_GATE

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

# The mistake this gate names.
run_case "record chained with push blocked" 2 \
  '"$HOME/.claude/scripts/record-verify-pass.sh" && git push'
run_case "record chained with push -u origin HEAD blocked" 2 \
  'record-verify-pass.sh && git push -u origin HEAD'
run_case "record chained with force-with-lease blocked" 2 \
  'record-verify-pass.sh && git push --force-with-lease'
run_case "push before record in the same line blocked" 2 \
  'git push origin main; record-verify-pass.sh'

# Each on its own is the correct form.
run_case "record alone allowed" 0 '"$HOME/.claude/scripts/record-verify-pass.sh"'
run_case "push alone allowed" 0 'git push origin feat/topic'

# Pushes that never consult the marker are not this mistake.
run_case "record chained with tag-only push allowed" 0 \
  'record-verify-pass.sh && git push --tags'
run_case "record chained with a delete push allowed" 0 \
  'record-verify-pass.sh && git push origin --delete old-branch'

# Reading the marker is fine in the same line — only writing it is the problem.
run_case "reading the marker then pushing allowed" 0 \
  'cat .git/verify-done-ok && git push origin feat/topic'

# Unrelated commands must not be caught.
run_case "unrelated command allowed" 0 'npm test && git push'

# The bypass must work.
SKIP_MARKER_CHAIN_GATE=1 run_case "bypass allows the chained form" 0 \
  'record-verify-pass.sh && git push'

echo
echo "passed: $pass, failed: $fail"
[ "$fail" -eq 0 ]
