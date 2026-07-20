#!/usr/bin/env bash
# Regression tests for hooks/pre-push-gate.sh.
#
# Each case runs the hook from a fixture package directory and asserts on the
# exit code (0 = allowed, 2 = blocked). Run: bash pre-push-gate.test.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# A failed mktemp must never leak this suite's git commands into the real repo.
cd "$(mktemp -d "${TMPDIR:-/tmp}/hooktest-cwd.XXXXXX")" || exit 1
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
bad=$(mktemp -d "${TMPDIR:-/tmp}/hooktest.XXXXXX")
printf '{"name":"bad","scripts":{"lint":"exit 1","test":"exit 0"}}' > "$bad/package.json"
touch "$bad/package-lock.json"

# Fixture: package whose scripts all pass.
good=$(mktemp -d "${TMPDIR:-/tmp}/hooktest.XXXXXX")
printf '{"name":"good","scripts":{"lint":"exit 0","typecheck":"exit 0","test":"exit 0","build":"exit 0"}}' > "$good/package.json"
touch "$good/package-lock.json"

# Fixture: no package.json at all.
empty=$(mktemp -d "${TMPDIR:-/tmp}/hooktest.XXXXXX")

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

# --- verify-done marker trust and target resolution ---------------------------
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@test
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@test

# Fixture: git repo whose lint fails — only a trusted marker lets a push through.
badrepo=$(mktemp -d "${TMPDIR:-/tmp}/hooktest.XXXXXX")
(cd "$badrepo" && git init -q -b feat/x \
  && git config user.email test@test && git config user.name test \
  && git commit -q --allow-empty -m "chore: init")
printf '{"name":"badrepo","scripts":{"lint":"exit 1"}}' > "$badrepo/package.json"
touch "$badrepo/package-lock.json"

run_case "repo without marker falls back to suite (blocked)" 2 "$badrepo" 'git push origin feat/x'

# The marker's first line is the verified HEAD; the gate trusts it only while
# HEAD still matches (what /verify-done records with `git rev-parse HEAD`).
git -C "$badrepo" rev-parse HEAD > "$badrepo/.git/verify-done-ok"
run_case "fresh marker trusted: suite not re-run" 0 "$badrepo" 'git push origin feat/x'

# Marker recorded for an earlier commit: HEAD moves, the mtime-fresh marker no
# longer matches, so the failing suite runs and blocks.
(cd "$badrepo" && git commit -q --allow-empty -m "chore: second")
run_case "marker for an earlier commit falls back to suite (blocked)" 2 "$badrepo" 'git push origin feat/x'

# A date-only marker (pre-HEAD-binding format) carries no SHA — never trusted.
date > "$badrepo/.git/verify-done-ok"
run_case "legacy date-only marker falls back to suite (blocked)" 2 "$badrepo" 'git push origin feat/x'

# Re-record for the current HEAD, then backdate: a stale mtime is not trusted.
git -C "$badrepo" rev-parse HEAD > "$badrepo/.git/verify-done-ok"
touch -t 202601010000 "$badrepo/.git/verify-done-ok"
run_case "stale marker falls back to suite (blocked)" 2 "$badrepo" 'git push origin feat/x'

# The gate must act on the checkout the push targets, not the hook's cwd —
# `git -C <path>` and a leading `cd <path> &&` both name it explicitly.
neutral=$(mktemp -d "${TMPDIR:-/tmp}/hooktest.XXXXXX")
rm -f "$badrepo/.git/verify-done-ok"
run_case "-C target's suite runs from elsewhere (blocked)" 2 "$neutral" "git -C $badrepo push origin feat/x"
run_case "leading cd target's suite runs from elsewhere (blocked)" 2 "$neutral" "cd $badrepo && git push origin feat/x"

git -C "$badrepo" rev-parse HEAD > "$badrepo/.git/verify-done-ok"
run_case "-C target's fresh marker trusted from elsewhere" 0 "$neutral" "git -C $badrepo push origin feat/x"

# --- deletion-only and tag-only exemptions ------------------------------------
# No marker: exit 0 must come from the exemption, not marker trust.
rm -f "$badrepo/.git/verify-done-ok"
run_case "deletion push exempt (no suite run)" 0 "$badrepo" 'git push origin --delete feat/old'
run_case "tag-only push exempt" 0 "$badrepo" 'git push origin --tags'
run_case "colon delete refspec exempt" 0 "$badrepo" 'git push origin :feat/old'
run_case "mixed delete and branch push still gated" 2 "$badrepo" 'git push origin feat/x :feat/old'
run_case "delete flag on continuation line exempt" 0 "$badrepo" 'git push origin \
  --delete feat/old'
run_case "quoted --delete is data: real push still gated" 2 "$badrepo" \
  'echo "git push --delete" && git push origin feat/x'

rm -rf "$bad" "$good" "$empty" "$badrepo" "$neutral"

echo ""
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
