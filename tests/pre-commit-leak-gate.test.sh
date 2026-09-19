#!/usr/bin/env bash
# Regression tests for hooks/pre-commit-leak-gate.sh.
# Run: bash pre-commit-leak-gate.test.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="$SCRIPT_DIR/../hooks/pre-commit-leak-gate.sh"

FIXTURE="$(mktemp -d "${TMPDIR:-/tmp}/commitleak.XXXXXX")" || exit 1
trap 'rm -rf "$FIXTURE"' EXIT
cd "$FIXTURE" || exit 1

git init -q . 2>/dev/null || exit 1
git config user.email t@example.com
git config user.name T
: >.leak-guard

PATTERNS="$FIXTURE/leak-patterns"
printf '%s\n' '# private list' 'acmecorp' >"$PATTERNS"
export CLAUDE_LEAK_PATTERNS="$PATTERNS"

pass=0
fail=0

run_case() { # run_case <name> <expected-exit> <command-string>
  local name="$1" expected="$2" command="$3" got
  jq -n --arg cmd "$command" --arg cwd "$PWD" '{tool_input:{command:$cmd},cwd:$cwd}' |
    bash "$SUT" >/dev/null 2>&1
  got=$?
  if [ "$got" = "$expected" ]; then
    echo "PASS: $name (exit $got)"
    pass=$((pass + 1))
  else
    echo "FAIL: $name — expected exit $expected, got $got"
    fail=$((fail + 1))
  fi
}

stage() { # stage <file> <content>
  printf '%s\n' "$2" >"$1"
  git add "$1" 2>/dev/null
}

# The exact miss this gate exists for: an identifier inside a staged FILE, which
# the outbound gate never sees because it only reads what a gh command publishes.
stage fixture.sh 'run_case "x" 2 "gh pr create --title ABC-1234"'
run_case "ticket key in staged file content is blocked" 2 'git commit -m "hooks: add a gate"'

git reset -q
stage clean.sh 'run_case "x" 2 "gh pr create --title generic"'
run_case "clean staged content passes" 0 'git commit -m "hooks: add a gate"'

run_case "ticket key in the commit message is blocked" 2 'git commit -m "ABC-1234: add a gate"'

run_case "private pattern in the message is blocked" 2 'git commit -m "hooks: work for AcmeCorp"'

git reset -q
stage client.sh 'const vendor = "acmecorp";'
run_case "private pattern in staged content is blocked" 2 'git commit -m "hooks: add a gate"'

git reset -q
stage clean2.sh 'const vendor = "generic";'
run_case "a non-commit git command is ignored" 0 'git status'

SKIP_LEAK_GATE=1 run_case "bypass env var disables the gate" 0 'git commit -m "ABC-1 leak"'

# Scoping: without the marker a client repo commits its own identifiers freely.
rm -f .leak-guard
run_case "no .leak-guard marker means the gate is inert" 0 'git commit -m "ABC-1234: real work"'
: >.leak-guard

# The gate must read the repo the command targets, not the session's cwd.
OUTSIDE="$(mktemp -d "${TMPDIR:-/tmp}/commitleak-outside.XXXXXX")"
(
  cd "$OUTSIDE" || exit 1
  git init -q . 2>/dev/null
  jq -n --arg cmd "git -C $FIXTURE commit -m \"ABC-1234: x\"" --arg cwd "$PWD" \
    '{tool_input:{command:$cmd},cwd:$cwd}' | bash "$SUT" >/dev/null 2>&1
  [ $? -eq 2 ]
) && { echo "PASS: git -C into the guarded repo is honoured (exit 2)"; pass=$((pass + 1)); } ||
  { echo "FAIL: git -C into the guarded repo is honoured"; fail=$((fail + 1)); }
rm -rf "$OUTSIDE"

# Removing an identifier must not be blocked: scanning a whole diff catches the
# deletion too, which punishes the cleanup and leaves the bypass as the only route.
git reset -q
stage tracked.sh 'const ticket = "ABC-1234";'
SKIP_LEAK_GATE=1 git commit -qm "seed" 2>/dev/null
stage tracked.sh 'const ticket = "generic";'
run_case "removing an identifier is not blocked" 0 'git commit -m "hooks: drop the identifier"'
SKIP_LEAK_GATE=1 git commit -qm "cleanup" 2>/dev/null

# An allow glob exempts file content so a matcher's own fixtures can be committed,
# but never the message — otherwise the exemption becomes a hole.
printf '%s\n' 'allow: tests/fixtures.sh' >>.leak-guard
git reset -q
mkdir -p tests
stage tests/fixtures.sh 'run_case "x" 2 "ABC-1234"'
run_case "an allowed path is exempt from the content scan" 0 'git commit -m "hooks: add a gate"'
run_case "an allowed path does not exempt the commit message" 2 'git commit -m "ABC-1234: x"'

git reset -q
stage tests/not-allowed.sh 'run_case "x" 2 "ABC-1234"'
run_case "a path outside the allow list is still scanned" 2 'git commit -m "hooks: add a gate"'

echo ""
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
