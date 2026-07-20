#!/usr/bin/env bash
# Regression tests for hooks/pre-pr-test-gate.sh.
# Run: bash pre-pr-test-gate.test.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# A failed mktemp must never leak this suite's git commands into the real repo.
cd "$(mktemp -d "${TMPDIR:-/tmp}/hooktest-cwd.XXXXXX")" || exit 1
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

failing=$(mktemp -d "${TMPDIR:-/tmp}/hooktest.XXXXXX")
printf '{"name":"failing","scripts":{"test":"exit 1"}}' > "$failing/package.json"
touch "$failing/package-lock.json"

passing=$(mktemp -d "${TMPDIR:-/tmp}/hooktest.XXXXXX")
printf '{"name":"passing","scripts":{"test":"exit 0"}}' > "$passing/package.json"
touch "$passing/package-lock.json"

placeholder=$(mktemp -d "${TMPDIR:-/tmp}/hooktest.XXXXXX")
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

# --- verify-done marker trust and checkout resolution --------------------------
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@test
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@test

# Fixture: git repo whose tests fail — only a trusted marker lets the PR through.
failrepo=$(mktemp -d "${TMPDIR:-/tmp}/hooktest.XXXXXX")
(cd "$failrepo" && git init -q -b feat/x \
  && git config user.email test@test && git config user.name test \
  && git commit -q --allow-empty -m "chore: init")
printf '{"name":"failrepo","scripts":{"test":"exit 1"}}' > "$failrepo/package.json"
touch "$failrepo/package-lock.json"

run_case "repo without marker falls back to tests (blocked)" 2 "$failrepo" 'gh pr create --fill'

date > "$failrepo/.git/verify-done-ok"
run_case "fresh marker trusted: tests not re-run" 0 "$failrepo" 'gh pr create --fill'

touch -t 202601010000 "$failrepo/.git/verify-done-ok"
run_case "stale marker falls back to tests (blocked)" 2 "$failrepo" 'gh pr create --fill'

# Payload cwd is where the gate acts: the hook is wired directly (no
# dispatcher cd), so worktree flows depend on it resolving the payload's cwd.
neutral=$(mktemp -d "${TMPDIR:-/tmp}/hooktest.XXXXXX")
rm -f "$failrepo/.git/verify-done-ok"
jq -n --arg cmd 'gh pr create --fill' --arg cwd "$failrepo" '{cwd:$cwd, tool_input:{command:$cmd}}' \
  | (cd "$neutral" && bash "$SUT") >/dev/null 2>&1
if [ $? -eq 2 ]; then
  echo "PASS: payload cwd resolves the checkout (blocked)"
  pass=$((pass + 1))
else
  echo "FAIL: payload cwd resolves the checkout — expected exit 2"
  fail=$((fail + 1))
fi

run_case "leading cd target's tests run from elsewhere (blocked)" 2 "$neutral" "cd $failrepo && gh pr create --fill"

date > "$failrepo/.git/verify-done-ok"
run_case "leading cd target's fresh marker trusted from elsewhere" 0 "$neutral" "cd $failrepo && gh pr create --fill"

rm -rf "$failing" "$passing" "$placeholder" "$failrepo" "$neutral"

echo ""
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
