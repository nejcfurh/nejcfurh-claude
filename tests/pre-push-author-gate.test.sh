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

# Stacking on a colleague's fetched branch must not block: their commits are
# reachable from refs/remotes/*, so only the user's own additions count.
stacked=$(make_repo)
git -C "$stacked" checkout -q -b tmp-colleague
GIT_AUTHOR_NAME=colleague GIT_AUTHOR_EMAIL=colleague@test \
  git -C "$stacked" commit -q --allow-empty -m "colleague work"
git -C "$stacked" push -q origin tmp-colleague:colleague-branch
git -C "$stacked" checkout -q main
git -C "$stacked" branch -q -D tmp-colleague
git -C "$stacked" fetch -q origin
git -C "$stacked" checkout -q -b feat/stacked --no-track origin/colleague-branch
git -C "$stacked" commit -q --allow-empty -m "feat: my addition"
run_case "stacked on colleague branch allowed" 0 "$stacked" 'git push -u origin feat/stacked'

# No remote at all -> range undeterminable -> never block.
lone=$(mktemp -d "${TMPDIR:-/tmp}/hooktest.XXXXXX")
(cd "$lone" && git init -q -b main && git config user.email me@test \
  && GIT_AUTHOR_EMAIL=test@test git commit -q --allow-empty -m x)
run_case "no remote never blocks" 0 "$lone" 'git push origin main'

# Deletion and tag pushes carry no commits.
run_case "deletion push exempt" 0 "$foreign" 'git push origin --delete feat/old'
run_case "tag push exempt" 0 "$foreign" 'git push origin --tags'
run_case "non-push command ignored" 0 "$foreign" 'git status'

# Any git-level option before `push` used to make the detection regex miss, so
# the gate exited 0 and published the foreign commit unchecked.
run_case "--no-pager push with foreign author blocked" 2 "$foreign" \
  'git --no-pager push -u origin feat/y'
run_case "--git-dir push with foreign author blocked" 2 "$foreign" \
  'git --git-dir=.git --work-tree=. push -u origin feat/y'
run_case "double-space push with foreign author blocked" 2 "$foreign" \
  'git  push -u origin feat/y'

# --follow-tags publishes the current branch too, so its commits must be checked.
run_case "--follow-tags with foreign author blocked" 2 "$foreign" 'git push --follow-tags'

# The gate must scan the ref being PUSHED, not HEAD. A foreign commit parked on
# another branch used to publish unchecked from a clean checkout.
crossref=$(make_repo)
git -C "$crossref" checkout -q -b feat/clean
git -C "$crossref" commit -q --allow-empty -m "feat: mine"
git -C "$crossref" checkout -q -b feat/dirty
GIT_AUTHOR_NAME=other GIT_AUTHOR_EMAIL=other@example.com \
  git -C "$crossref" commit -q --allow-empty -m "fixture junk"
git -C "$crossref" checkout -q feat/clean
run_case "foreign commit on another branch blocked" 2 "$crossref" \
  'git push origin feat/dirty'
run_case "explicit refspec of the foreign branch blocked" 2 "$crossref" \
  'git push origin feat/dirty:feat/dirty'
run_case "clean branch from the same checkout allowed" 0 "$crossref" \
  'git push origin feat/clean'
run_case "--all covering the foreign branch blocked" 2 "$crossref" 'git push --all origin'

# An exemption on one invocation must not cover the whole command line.
run_case "exempt tag push then real push blocked" 2 "$foreign" \
  'git push origin --tags && git push -u origin feat/y'

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

rm -rf "$mine" "$foreign" "$upstream" "$stacked" "$lone"

echo ""
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
