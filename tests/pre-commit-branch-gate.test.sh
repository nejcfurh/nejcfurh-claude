#!/usr/bin/env bash
# Regression tests for hooks/pre-commit-branch-gate.sh.
#
# Each case pipes a PreToolUse JSON payload into the hook from a throwaway
# repo and asserts on the exit code (0 = allowed, 2 = blocked). Covers the
# cross-repo cases: `git -C <path>` and `cd <path> &&` must gate on the
# TARGET repo's branch, not the cwd's. Run: bash pre-commit-branch-gate.test.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# A failed mktemp must never leak this suite's git commands into the real repo.
cd "$(mktemp -d "${TMPDIR:-/tmp}/hooktest-cwd.XXXXXX")" || exit 1
SUT="$SCRIPT_DIR/../hooks/pre-commit-branch-gate.sh"

pass=0
fail=0

export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@test
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@test
unset CLAUDE_PROJECT_DIR

make_repo() { # make_repo <branch> -> prints repo path
  local r
  r=$(mktemp -d "${TMPDIR:-/tmp}/hooktest.XXXXXX")
  (cd "$r" && git init -q -b "$1" && git commit -q --allow-empty -m init)
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

main_repo=$(make_repo main)
master_repo=$(make_repo master)
feat_repo=$(make_repo feat/topic)

run_case "commit on main blocked" 2 "$main_repo" \
  'git commit -m "feat: x"'

run_case "commit on master blocked" 2 "$master_repo" \
  'git commit -m "feat: x"'

run_case "commit on feature branch allowed" 0 "$feat_repo" \
  'git commit -m "feat: x"'

run_case "non-commit command on main ignored" 0 "$main_repo" \
  'git status'

run_case "git -C feature repo allowed from main cwd" 0 "$main_repo" \
  "git -C $feat_repo commit -m \"feat: x\""

run_case "git -C quoted feature repo allowed from main cwd" 0 "$main_repo" \
  "git -C \"$feat_repo\" commit -m \"feat: x\""

run_case "git -C main repo blocked from feature cwd" 2 "$feat_repo" \
  "git -C $main_repo commit -m \"feat: x\""

run_case "cd feature repo allowed from main cwd" 0 "$main_repo" \
  "cd $feat_repo && git commit -m \"feat: x\""

run_case "cd main repo blocked from feature cwd" 2 "$feat_repo" \
  "cd $main_repo && git commit -m \"feat: x\""

# Compound commands that switch branches BEFORE committing must be judged by
# the branch the commit will actually land on, not the pre-execution branch.
run_case "checkout -b then commit allowed from main cwd" 0 "$main_repo" \
  'git checkout -b feat/new-thing && git commit -m "feat: x"'

run_case "switch -c then commit allowed from main cwd" 0 "$main_repo" \
  'git switch -c feat/new-thing && git commit -m "feat: x"'

run_case "checkout main then commit blocked from feature cwd" 2 "$feat_repo" \
  'git checkout main && git commit -m "feat: x"'

run_case "checkout -b main then commit still blocked" 2 "$feat_repo" \
  'git checkout -b main && git commit -m "feat: x"'

# Bypass env var must allow anything through.
jq -n --arg cmd 'git commit -m "x"' '{tool_input:{command:$cmd}}' \
  | (cd "$main_repo" && SKIP_COMMIT_BRANCH_GATE=1 bash "$SUT") >/dev/null 2>&1
if [ $? -eq 0 ]; then
  echo "PASS: bypass env allows commit on main (exit 0)"
  pass=$((pass + 1))
else
  echo "FAIL: bypass env allows commit on main — expected exit 0"
  fail=$((fail + 1))
fi

rm -rf "$main_repo" "$master_repo" "$feat_repo"

echo ""
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
