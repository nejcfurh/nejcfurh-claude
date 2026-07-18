#!/usr/bin/env bash
# Regression tests for hooks/pre-push-author-gate.sh.
#
# Each case pipes a PreToolUse JSON payload into the hook from a throwaway
# repo (with a bare "remote") and asserts on the exit code (0 = allowed,
# 2 = blocked). Run: bash pre-push-author-gate.test.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# A failed mktemp must never leak this suite's git commands into the real repo.
cd "$(mktemp -d "${TMPDIR:-/tmp}/hooktest-cwd.XXXXXX")" || exit 1
SUT="$SCRIPT_DIR/../hooks/pre-push-author-gate.sh"

pass=0
fail=0

export GIT_AUTHOR_NAME=me GIT_AUTHOR_EMAIL=me@test
export GIT_COMMITTER_NAME=me GIT_COMMITTER_EMAIL=me@test
unset CLAUDE_PROJECT_DIR

make_repo() { # -> prints repo path: main pushed to a bare remote, user.email set
  local r bare
  r=$(mktemp -d "${TMPDIR:-/tmp}/hooktest.XXXXXX")
  bare=$(mktemp -d "${TMPDIR:-/tmp}/hooktest.XXXXXX")
  git init -q --bare "$bare"
  (
    cd "$r" || exit 1
    git init -q -b main
    git config user.email me@test
    git commit -q --allow-empty -m init
    git remote add origin "$bare"
    git push -q -u origin main
  )
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

# Own commits push fine.
mine=$(make_repo)
git -C "$mine" checkout -q -b feat/x
git -C "$mine" commit -q --allow-empty -m "feat: mine"
run_case "own commits allowed" 0 "$mine" 'git push -u origin feat/x'

# A foreign-author commit in the outgoing range blocks.
foreign=$(make_repo)
git -C "$foreign" checkout -q -b feat/y
git -C "$foreign" commit -q --allow-empty -m "feat: mine"
GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@test \
  git -C "$foreign" commit -q --allow-empty -m "fixture junk"
run_case "foreign author blocked" 2 "$foreign" 'git push -u origin feat/y'

# With an upstream set, only commits past it count.
upstream=$(make_repo)
GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@test \
  git -C "$upstream" commit -q --allow-empty -m "already on remote"
git -C "$upstream" push -q origin main 2>/dev/null
git -C "$upstream" commit -q --allow-empty -m "feat: mine"
run_case "foreign commit already upstream ignored" 0 "$upstream" 'git push'

# No remote at all -> range undeterminable -> never block.
lone=$(mktemp -d "${TMPDIR:-/tmp}/hooktest.XXXXXX")
(cd "$lone" && git init -q -b main && git config user.email me@test \
  && GIT_AUTHOR_EMAIL=test@test git commit -q --allow-empty -m x)
run_case "no remote never blocks" 0 "$lone" 'git push origin main'

# Deletion and tag pushes carry no commits.
run_case "deletion push exempt" 0 "$foreign" 'git push origin --delete feat/old'
run_case "tag push exempt" 0 "$foreign" 'git push origin --tags'
run_case "non-push command ignored" 0 "$foreign" 'git status'

# Bypass env var must allow anything through.
jq -n --arg cmd 'git push -u origin feat/y' '{tool_input:{command:$cmd}}' \
  | (cd "$foreign" && SKIP_PUSH_AUTHOR_GATE=1 bash "$SUT") >/dev/null 2>&1
if [ $? -eq 0 ]; then
  echo "PASS: bypass env allows push (exit 0)"
  pass=$((pass + 1))
else
  echo "FAIL: bypass env allows push — expected exit 0"
  fail=$((fail + 1))
fi

rm -rf "$mine" "$foreign" "$upstream" "$lone"

echo ""
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
