#!/usr/bin/env bash
# Regression tests for hooks/pre-gh-outbound-leak-gate.sh.
# Run: bash pre-gh-outbound-leak-gate.test.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="$SCRIPT_DIR/../hooks/pre-gh-outbound-leak-gate.sh"

FIXTURE="$(mktemp -d "${TMPDIR:-/tmp}/leakgate.XXXXXX")" || exit 1
trap 'rm -rf "$FIXTURE"' EXIT
cd "$FIXTURE" || exit 1

git init -q . 2>/dev/null || exit 1
: >.leak-guard

PATTERNS="$FIXTURE/leak-patterns"
printf '%s\n' '# private list' 'acmecorp' >"$PATTERNS"
export CLAUDE_LEAK_PATTERNS="$PATTERNS"

# Derived terms come from the real project list otherwise, which would make these
# suites depend on whatever the developer happens to have checked out.
PROJECTS="$FIXTURE/projects"
mkdir -p "$PROJECTS/-Users-x-Development-Contoso-widgetworks"
export CLAUDE_PROJECTS_DIR="$PROJECTS"

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

printf '%s\n' 'Fixes ABC-1234 in the checkout flow.' >body-ticket.md
printf '%s\n' 'Sharpens an existing rule about controls.' >body-clean.md
printf '%s\n' 'Work delivered for AcmeCorp this week.' >body-client.md

run_case "ticket key in a body file is blocked" 2 \
  'gh pr create --base main --title "rules: x" --body-file body-ticket.md'

run_case "ticket key inline on the command line is blocked" 2 \
  'gh pr create --base main --title "XYZ-4321: fix the thing" --body "short"'

run_case "clean body passes" 0 \
  'gh pr create --base main --title "rules: x" --body-file body-clean.md'

run_case "private pattern in a body file is blocked" 2 \
  'gh pr create --base main --title "rules: x" --body-file body-client.md'

run_case "-F body=@file form is scanned" 2 \
  'gh api --method PATCH repos/o/r/pulls/1 -F body=@body-ticket.md'

run_case "issue comment is scanned" 2 \
  'gh issue comment 4 --body-file body-ticket.md'

run_case "a read command is not scanned" 0 \
  'gh pr view 87 --json body'

run_case "unrelated command is ignored" 0 \
  'git status'

SKIP_LEAK_GATE=1 run_case "bypass env var disables the gate" 0 \
  'gh pr create --base main --title "ABC-1 leak" --body "x"'

# The command may cd into the guarded repo from elsewhere; the payload's cwd is the
# session's, not that one. Missing this is a false ALLOW at exactly the moment the
# command is reaching into the repo being protected.
OUTSIDE="$(mktemp -d "${TMPDIR:-/tmp}/leakgate-outside.XXXXXX")"
(
  cd "$OUTSIDE" || exit 1
  git init -q . 2>/dev/null
  jq -n --arg cmd "cd $FIXTURE && gh pr create --base main --body-file body-ticket.md" \
    '{tool_input:{command:$cmd}}' | bash "$SUT" >/dev/null 2>&1
  [ $? -eq 2 ]
) && { echo "PASS: leading cd into the guarded repo is honoured (exit 2)"; pass=$((pass + 1)); } ||
  { echo "FAIL: leading cd into the guarded repo is honoured"; fail=$((fail + 1)); }
rm -rf "$OUTSIDE"

# The marker is what scopes this to repos meant to stay generic. Without it a
# client repo naming its own client in every PR body would be blocked, which is
# how a gate teaches its own bypass.
rm -f .leak-guard
run_case "no .leak-guard marker means the gate is inert" 0 \
  'gh pr create --base main --title "ABC-1234" --body-file body-ticket.md'
: >.leak-guard

# A missing private list must not fail open on the built-in class.
unset CLAUDE_LEAK_PATTERNS
export CLAUDE_LEAK_PATTERNS="$FIXTURE/does-not-exist"
run_case "built-in ticket class still fires with no private list" 2 \
  'gh pr create --base main --title "x" --body-file body-ticket.md'

# A body file under a project directory names that project in its path. If that
# counts as a leak, nothing can ever be published from the guarded repo.
run_case "a project name in a path argument is not a leak" 0 \
  "gh pr create --base main --title 'rules: x' --body-file /Users/x/Development/Contoso/widgetworks/body-clean.md"

echo ""
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
