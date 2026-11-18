#!/usr/bin/env bash
# Regression tests for hooks/pre-git-check-chain-gate.sh.
#
# Each case pipes a PreToolUse JSON payload into the hook and asserts on the
# exit code (0 = allowed, 2 = blocked). The gate exists because a commit chained
# after a check with `;` lands even when the check failed.
# Run: bash pre-git-check-chain-gate.test.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

cd "$(mktemp -d "${TMPDIR:-/tmp}/hooktest-cwd.XXXXXX")" || exit 1
SUT="$SCRIPT_DIR/../hooks/pre-git-check-chain-gate.sh"
DISPATCH="$SCRIPT_DIR/../hooks/git-gate-dispatch.sh"

pass=0
fail=0

unset SKIP_CHECK_CHAIN_GATE

run_case() { # run_case <name> <expected-exit> <command-string>
  name="$1" expected="$2" command="$3"
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

# The mistake this gate names: the check's failure does not stop the git step.
run_case "lint then commit with ; blocked" 2 'npm run lint; git commit -m "x"'
run_case "last of three checks joined with ; blocked" 2 \
  'npm run lint && npm run format && npm run check ; git commit -m "x"'
run_case "check then commit on the next line blocked" 2 $'npm test\ngit commit -m x'
run_case "check || true && commit blocked" 2 'npx tsc --noEmit || true && git commit -m x'
run_case "check piped to tail without pipefail blocked" 2 \
  'npm run test 2>&1 | tail -5 && git commit -m x'
run_case "an earlier check joined with ; blocked" 2 \
  'npm run lint; npm run format && git commit -m x'
run_case "backgrounded build then push blocked" 2 'npm run build & git push origin feat/x'
run_case "git -C commit right after ; blocked" 2 \
  'cd /repo && npm run lint;git -C /repo commit -m x'
run_case "shell suite then push blocked" 2 'bash tests/run-all.sh; git push'
run_case "cargo test then commit blocked" 2 'cargo test; git commit -am x'

# The correct form and the explicit guards.
run_case "every step joined with && allowed" 0 \
  'npm run lint && npm run format && npm run check && git commit -m x'
run_case "redirection & is not a separator" 0 'npm run lint 2>&1 && git commit -m x'
run_case "set -e makes ; safe" 0 'set -e; npm run lint; git commit -m x'
run_case "set -euo pipefail makes a pipe safe" 0 \
  'set -euo pipefail; npm test | tee log; git commit -m x'
run_case "check || exit 1 is a guard" 0 'npm run lint || exit 1; git commit -m x'
run_case "heredoc message after && allowed" 0 \
  $'npm run lint && git commit -m "$(cat <<\'EOF\'\nfeat: x\n\nbody; more\nEOF\n)"'

# Not this mistake.
run_case "commit with no check allowed" 0 'git commit -m "x; y"'
run_case "non-check steps joined with ; allowed" 0 'cd /repo; git status; git commit -m x'
run_case "check after the git command allowed" 0 'git commit -m x && npm run lint; echo done'
run_case "no git step allowed" 0 'npm run lint; npm test'
run_case "quoted check text allowed" 0 'echo "npm run lint; ok" && git commit -m x'
run_case "push with no check allowed" 0 'git fetch; git push origin feat/x'

# The bypass must work.
SKIP_CHECK_CHAIN_GATE=1 run_case "bypass allows the chained form" 0 \
  'npm run lint; git commit -m x'

# End to end through the dispatcher, the path the harness actually invokes.
got=$(jq -n --arg cmd 'npm run lint; git commit -m x' \
  '{tool_input:{command:$cmd}}' | bash "$DISPATCH" 2>&1 >/dev/null)
rc=$?
if [ "$rc" = 2 ] && printf '%s' "$got" | grep -q 'ignores the check'; then
  echo "PASS: dispatcher routes a chained commit to this gate (exit $rc)"
  pass=$((pass + 1))
else
  echo "FAIL: dispatcher did not block with this gate's message (exit $rc)"
  fail=$((fail + 1))
fi

echo
echo "passed: $pass, failed: $fail"
[ "$fail" -eq 0 ]
