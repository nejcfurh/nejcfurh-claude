#!/usr/bin/env bash
# Regression tests for hooks/pre-push-verify-gate.sh.
#
# Each case pipes a PreToolUse JSON payload into the hook from a throwaway
# repo and asserts on the exit code (0 = allowed, 2 = blocked). The marker
# .git/verify-done-ok is what /verify-done writes on a READY verdict.
# Run: bash pre-push-verify-gate.test.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# A failed mktemp must never leak this suite's git commands into the real repo.
cd "$(mktemp -d "${TMPDIR:-/tmp}/hooktest-cwd.XXXXXX")" || exit 1
SUT="$SCRIPT_DIR/../hooks/pre-push-verify-gate.sh"

pass=0
fail=0

export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@test
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@test
unset CLAUDE_PROJECT_DIR

make_repo() { # -> prints repo path
  local r
  r=$(mktemp -d "${TMPDIR:-/tmp}/hooktest.XXXXXX")
  (cd "$r" && git init -q -b feat/topic && git commit -q --allow-empty -m init)
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

bare=$(make_repo)
run_case "push without marker blocked" 2 "$bare" 'git push origin feat/topic'

fresh=$(make_repo)
date > "$fresh/.git/verify-done-ok"
run_case "push with fresh marker allowed" 0 "$fresh" 'git push origin feat/topic'

stale=$(make_repo)
date > "$stale/.git/verify-done-ok"
touch -t 202601010000 "$stale/.git/verify-done-ok"
run_case "push with stale marker blocked" 2 "$stale" 'git push origin feat/topic'

run_case "deletion push exempt" 0 "$bare" 'git push origin --delete feat/old'
run_case "tag push exempt" 0 "$bare" 'git push origin --tags'
run_case "non-push command ignored" 0 "$bare" 'git status'

run_case "git -C fresh repo allowed from bare cwd" 0 "$bare" \
  "git -C $fresh push origin feat/topic"
run_case "git -C bare repo blocked from fresh cwd" 2 "$fresh" \
  "git -C $bare push origin feat/topic"

# TTL override: a marker older than a tiny TTL is stale.
jq -n --arg cmd 'git push origin feat/topic' '{tool_input:{command:$cmd}}' \
  | (cd "$stale" && VERIFY_DONE_TTL_MINUTES=1 bash "$SUT") >/dev/null 2>&1
if [ $? -eq 2 ]; then
  echo "PASS: TTL override respected (exit 2)"
  pass=$((pass + 1))
else
  echo "FAIL: TTL override respected — expected exit 2"
  fail=$((fail + 1))
fi

# Bypass env var must allow anything through.
jq -n --arg cmd 'git push origin feat/topic' '{tool_input:{command:$cmd}}' \
  | (cd "$bare" && SKIP_VERIFY_GATE=1 bash "$SUT") >/dev/null 2>&1
if [ $? -eq 0 ]; then
  echo "PASS: bypass env allows push (exit 0)"
  pass=$((pass + 1))
else
  echo "FAIL: bypass env allows push — expected exit 0"
  fail=$((fail + 1))
fi

rm -rf "$bare" "$fresh" "$stale"

echo ""
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
