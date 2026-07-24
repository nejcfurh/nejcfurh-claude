#!/usr/bin/env bash
# Regression tests for hooks/pre-commit-conventional-gate.sh.
#
# Each case pipes a PreToolUse JSON payload into the hook and asserts on the
# exit code (0 = allowed, 2 = blocked). Run: bash pre-commit-conventional-gate.test.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# A failed mktemp must never leak this suite's git commands into the real repo.
cd "$(mktemp -d "${TMPDIR:-/tmp}/hooktest-cwd.XXXXXX")" || exit 1
SUT="$SCRIPT_DIR/../hooks/pre-commit-conventional-gate.sh"

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

run_case "valid subject with scope" 0 \
  'git commit -m "feat(auth): add passwordless login"'

run_case "valid subject without scope" 0 \
  'git commit -m "fix: handle empty diff"'

run_case "breaking-change marker allowed" 0 \
  'git commit -m "feat(api)!: drop v1 endpoints"'

run_case "deps type allowed" 0 \
  'git commit -m "deps(api): bump fastify to v5"'

run_case "security type allowed" 0 \
  'git commit -m "security: patch header injection"'

run_case "unknown type blocked" 2 \
  'git commit -m "feature(auth): add login"'

run_case "no conventional prefix blocked" 2 \
  'git commit -m "added some stuff"'

run_case "amend passes through" 0 \
  'git commit --amend --no-edit'

run_case "fixup passes through" 0 \
  'git commit --fixup HEAD'

run_case "merge commit exempt" 0 \
  'git commit -m "Merge branch main into feature"'

run_case "revert commit exempt" 0 \
  'git commit -m "Revert \"feat(auth): add login\""'

run_case "heredoc valid subject" 0 \
  'git commit -m "$(cat <<EOF
fix(core): handle empty diff
Body line here.
EOF
)"'

run_case "heredoc invalid subject blocked" 2 \
  'git commit -m "$(cat <<EOF
did some things
EOF
)"'

run_case "non-commit command ignored" 0 \
  'git status'

run_case "git -C form with bad subject blocked" 2 \
  'git -C /some/repo commit -m "added some stuff"'

run_case "git -C form with valid subject allowed" 0 \
  'git -C /some/repo commit -m "feat(auth): add login"'

# Git-level options sit between `git` and the subcommand, so the literal
# substring "git commit" this gate used to fall back to matched none of these.
run_case "--no-pager form with bad subject blocked" 2 \
  'git --no-pager commit -m "added some stuff"'

run_case "double-space form with bad subject blocked" 2 \
  'git  commit -m "added some stuff"'

run_case "--git-dir form with bad subject blocked" 2 \
  'git --git-dir=.git commit -m "added some stuff"'

run_case "--no-pager form with valid subject allowed" 0 \
  'git --no-pager commit -m "feat(auth): add login"'

# Every spelling git accepts for the message. The sed extractors this replaced
# recognised only -m "…" and -m '…', so each of these extracted no subject and
# the gate failed open — `-am` especially, which is an everyday form.
run_case "--message= with bad subject blocked" 2   'git commit --message="added stuff"'
run_case "--message with bad subject blocked" 2    'git commit --message "added stuff"'
run_case "-am with bad subject blocked" 2          'git commit -am "added stuff"'
run_case "bare -m value with bad subject blocked" 2 'git commit -m wip'
run_case "attached -mvalue with bad subject blocked" 2 'git commit -mwip'
run_case "attached -amvalue with bad subject blocked" 2 'git commit -amwip'

run_case "--message= with valid subject allowed" 0 'git commit --message="feat(auth): add login"'
run_case "-am with valid subject allowed" 0        'git commit -am "feat(auth): add login"'
# An unquoted message cannot contain a space, so it can never be a conventional
# subject (`feat:x` has no space after the colon) — it must block, not slip by.
run_case "bare -m value without a space blocked" 2 'git commit -m feat:x'

# `-c`/`-C` reuse an existing message and are exempt — but only as flags. Matching
# them anywhere in the raw command let a message that merely mentions one skip.
run_case "-C HEAD reuse exempt" 0                  'git commit -C HEAD'
run_case "--reuse-message exempt" 0                'git commit --reuse-message=HEAD'
run_case "message mentioning -c is still checked" 2 'git commit -m "wip: pass -c to jq"'
run_case "message mentioning -C is still checked" 2 'git commit -m "wip -C"'

# A body must not rescue an invalid subject, and must not break a valid one.
run_case "multi-line valid subject allowed" 0 'git commit -m "feat: ok

body line"'
run_case "multi-line invalid subject blocked" 2 'git commit -m "wip

body line"'

# Bypass env var must allow anything through.
jq -n --arg cmd 'git commit -m "junk"' '{tool_input:{command:$cmd}}' \
  | SKIP_CONVENTIONAL_GATE=1 bash "$SUT" >/dev/null 2>&1
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
