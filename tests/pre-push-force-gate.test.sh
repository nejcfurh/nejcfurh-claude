#!/usr/bin/env bash
# Regression tests for hooks/pre-push-force-gate.sh.
#
# Each case pipes a PreToolUse JSON payload into the hook and asserts on the
# exit code (0 = allowed, 2 = blocked). The gate is pure command parsing — no
# repo needed. Run: bash pre-push-force-gate.test.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# A failed mktemp must never leak this suite's git commands into the real repo.
cd "$(mktemp -d "${TMPDIR:-/tmp}/hooktest-cwd.XXXXXX")" || exit 1
SUT="$SCRIPT_DIR/../hooks/pre-push-force-gate.sh"

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

run_case "push --force blocked" 2 \
  'git push --force'

run_case "push -f blocked" 2 \
  'git push -f origin feat/x'

run_case "flag after refspec blocked" 2 \
  'git push origin main --force'

run_case "git -C path push --force blocked" 2 \
  'git -C /some/repo push --force origin feat/x'

run_case "force push in compound command blocked" 2 \
  'git commit -m "fix: x" && git push --force'

run_case "plain push allowed" 0 \
  'git push origin feat/x'

run_case "force-with-lease allowed" 0 \
  'git push --force-with-lease origin feat/x'

run_case "force-with-lease with value allowed" 0 \
  'git push --force-with-lease=feat/x:abc123 origin feat/x'

run_case "force-if-includes allowed" 0 \
  'git push --force-with-lease --force-if-includes origin feat/x'

run_case "rm -f before plain push not misread" 0 \
  'rm -f stale.lock && git push origin feat/x'

run_case "force flag after separator not this push" 0 \
  'git push origin feat/x; echo --force'

run_case "non-push command ignored" 0 \
  'git status --force'

run_case "bundled short flags -fu blocked" 2 \
  'git push -fu origin feat/x'

run_case "bundled short flags -uf blocked" 2 \
  'git push -uf origin feat/x'

run_case "plus-refspec force push blocked" 2 \
  'git push origin +feat/x'

run_case "plus-refspec with full ref blocked" 2 \
  'git push origin +refs/heads/feat/x:refs/heads/feat/x'

run_case "force flag on continuation line blocked" 2 \
  'git push \
  --force origin feat/x'

run_case "short flag without f allowed" 0 \
  'git push -u origin feat/x'

run_case "normal colon refspec allowed" 0 \
  'git push origin refs/heads/a:refs/heads/b'

run_case "force-with-lease on continuation line allowed" 0 \
  'git push --force-with-lease \
  origin feat/x'

run_case "plus sign inside commit message not a push arg" 0 \
  'git commit -m "docs: notes on push +refspec"'

# The exact false positive that blocked this fix's own release commit: gate
# filenames put "push" before the real subcommand, and the commit message
# mentions `git push` as data — the arg scan must anchor on the invocation.
run_case "gate filenames plus git-push mention in message allowed" 0 \
  'git add hooks/pre-push-force-gate.sh && git commit -m "docs: exempt the git push origin :dead form"'

run_case "filename before real force push still blocked" 2 \
  'git add hooks/pre-push-force-gate.sh && git push --force origin feat/x'

# Bypass env var must allow anything through.
jq -n --arg cmd 'git push --force' '{tool_input:{command:$cmd}}' \
  | SKIP_PUSH_FORCE_GATE=1 bash "$SUT" >/dev/null 2>&1
if [ $? -eq 0 ]; then
  echo "PASS: bypass env allows force push (exit 0)"
  pass=$((pass + 1))
else
  echo "FAIL: bypass env allows force push — expected exit 0"
  fail=$((fail + 1))
fi

echo ""
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
