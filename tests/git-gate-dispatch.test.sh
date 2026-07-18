#!/usr/bin/env bash
# Regression tests for hooks/git-gate-dispatch.sh — the single PreToolUse
# entry point that routes git commands to the individual gates. These cases
# assert ROUTING: each gate family is reachable through the dispatcher, a
# gate's block propagates as exit 2, SKIP_* bypasses reach the child gates,
# and the state-refresh context envelope only reaches stdout when nothing
# blocked. The gates' own behavior is covered by their dedicated suites.
# Run: bash git-gate-dispatch.test.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# A failed mktemp must never leak this suite's git commands into the real repo.
cd "$(mktemp -d "${TMPDIR:-/tmp}/hooktest-cwd.XXXXXX")" || exit 1
SUT="$SCRIPT_DIR/../hooks/git-gate-dispatch.sh"

pass=0
fail=0

export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@test
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@test
unset CLAUDE_PROJECT_DIR

make_repo() { # make_repo <branch> -> prints repo path
  local r
  r=$(mktemp -d "${TMPDIR:-/tmp}/hooktest.XXXXXX")
  (cd "$r" && git init -q -b "$1" \
    && git config user.email test@test && git config user.name test \
    && git commit -q --allow-empty -m "chore: init")
  printf '%s\n' "$r"
}

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

feature=$(make_repo feat/topic)
main=$(make_repo main)

run_case "non-git command passes through" 0 "$feature" 'ls -la'
run_case "git status routes to no gate" 0 "$feature" 'git status'

# Commit-gate family is reachable.
run_case "conventional commit on feature branch allowed" 0 "$feature" \
  'git commit -m "feat: add thing"'
run_case "commit on main blocked (branch gate)" 2 "$main" \
  'git commit -m "feat: add thing"'
run_case "coauthor commit blocked (coauthor gate)" 2 "$feature" \
  'git commit -m "feat: x" -m "Co-Authored-By: Claude <noreply@anthropic.com>"'
run_case "non-conventional message blocked (conventional gate)" 2 "$feature" \
  'git commit -m "added stuff"'

# Push-gate family is reachable.
run_case "force push blocked (force gate)" 2 "$feature" \
  'git push --force origin feat/topic'
run_case "push without verify marker blocked (verify gate)" 2 "$feature" \
  'git push origin feat/topic'

date > "$feature/.git/verify-done-ok"
run_case "push with fresh marker allowed" 0 "$feature" \
  'git push origin feat/topic'

# SKIP_* bypasses must reach the child gates through the dispatcher.
jq -n --arg cmd 'git push --force origin feat/topic' '{tool_input:{command:$cmd}}' \
  | (cd "$feature" && SKIP_PUSH_FORCE_GATE=1 bash "$SUT") >/dev/null 2>&1
if [ $? -eq 0 ]; then
  echo "PASS: SKIP env reaches child gate through dispatcher (exit 0)"
  pass=$((pass + 1))
else
  echo "FAIL: SKIP env reaches child gate through dispatcher — expected exit 0"
  fail=$((fail + 1))
fi

# state-refresh context envelope reaches stdout when nothing blocks...
out=$(jq -n --arg cmd 'git push origin feat/topic' '{tool_input:{command:$cmd}}' \
  | (cd "$feature" && bash "$SUT") 2>/dev/null)
case "$out" in
  *pr-state*)
    echo "PASS: allowed push emits pr-state context on stdout"
    pass=$((pass + 1))
    ;;
  *)
    echo "FAIL: allowed push emits pr-state context on stdout — got: $out"
    fail=$((fail + 1))
    ;;
esac

# ...and is suppressed when a gate blocks (no API round-trip, no mixed stdout).
rm -f "$feature/.git/verify-done-ok"
out=$(jq -n --arg cmd 'git push origin feat/topic' '{tool_input:{command:$cmd}}' \
  | (cd "$feature" && bash "$SUT") 2>/dev/null)
case "$out" in
  *pr-state*)
    echo "FAIL: blocked push must not emit pr-state context — got: $out"
    fail=$((fail + 1))
    ;;
  *)
    echo "PASS: blocked push emits no pr-state context"
    pass=$((pass + 1))
    ;;
esac

rm -rf "$feature" "$main"

echo ""
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
