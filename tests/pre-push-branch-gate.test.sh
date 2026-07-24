#!/usr/bin/env bash
# Regression tests for hooks/pre-push-branch-gate.sh.
#
# Each case builds a throwaway repo with origin/HEAD pointing at a default
# branch, then pipes a PreToolUse payload into the hook and asserts on the
# exit code (0 = allowed, 2 = blocked). The gate must resolve the ACTUAL push
# target — bare pushes, HEAD, refspecs — not string-match branch names.
# Run: bash pre-push-branch-gate.test.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# A failed mktemp must never leak this suite's git commands into the real repo.
cd "$(mktemp -d "${TMPDIR:-/tmp}/hooktest-cwd.XXXXXX")" || exit 1
SUT="$SCRIPT_DIR/../hooks/pre-push-branch-gate.sh"

pass=0
fail=0

export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@test
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@test
unset CLAUDE_PROJECT_DIR

make_repo() { # make_repo <default-branch> <checked-out-branch> -> prints repo path
  local default="$1" current="$2" r
  r=$(mktemp -d "${TMPDIR:-/tmp}/hooktest.XXXXXX")
  (
    cd "$r" || exit 1
    git init -q -b "$default"
    git commit -q --allow-empty -m init
    git update-ref "refs/remotes/origin/$default" "refs/heads/$default"
    git symbolic-ref "refs/remotes/origin/HEAD" "refs/remotes/origin/$default"
    [ "$current" != "$default" ] && git checkout -q -b "$current"
  ) >/dev/null 2>&1
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

on_main=$(make_repo main main)
on_feat=$(make_repo main feat/topic)
on_trunk=$(make_repo trunk trunk)
trunk_feat=$(make_repo trunk feat/topic)

# --- explicit branch pushes --------------------------------------------------
run_case "explicit push to main blocked" 2 "$on_feat" 'git push origin main'
run_case "explicit push of feature branch allowed" 0 "$on_feat" 'git push origin feat/topic'
run_case "force-with-lease of feature branch allowed" 0 "$on_feat" 'git push --force-with-lease origin feat/topic'

# --- the holes string-matching rules cannot see ------------------------------
run_case "bare push while on main blocked" 2 "$on_main" 'git push'
run_case "bare push while on feature branch allowed" 0 "$on_feat" 'git push'
run_case "push origin HEAD while on main blocked" 2 "$on_main" 'git push origin HEAD'
run_case "push origin HEAD while on feature allowed" 0 "$on_feat" 'git push origin HEAD'
run_case "refspec HEAD:main blocked" 2 "$on_feat" 'git push origin HEAD:main'
run_case "refspec feat:main blocked" 2 "$on_feat" 'git push origin feat/topic:main'
run_case "push --all blocked" 2 "$on_feat" 'git push --all origin'
run_case "delete of default branch blocked" 2 "$on_feat" 'git push origin --delete main'

# --- force pushes: allowed on feature branches, never on the default ----------
# With pre-push-force-gate removed, THIS gate is what keeps force pushes off
# the default branch — these cases must hold in every command form.
run_case "force push to main blocked" 2 "$on_feat" 'git push --force origin main'
run_case "-f push to main blocked" 2 "$on_feat" 'git push -f origin main'
run_case "plus-refspec to main blocked" 2 "$on_feat" 'git push origin +main'
run_case "plus-refspec full ref to main blocked" 2 "$on_feat" 'git push origin +refs/heads/main'
run_case "bare force push while on main blocked" 2 "$on_main" 'git push --force'
run_case "mirror push blocked (would overwrite default)" 2 "$on_feat" 'git push --mirror origin'
run_case "force push of feature branch allowed" 0 "$on_feat" 'git push --force origin feat/topic'
run_case "bare force push while on feature branch allowed" 0 "$on_feat" 'git push --force'

# --- default branch under a different name -----------------------------------
run_case "push to trunk blocked when trunk is default" 2 "$trunk_feat" 'git push origin trunk'
run_case "bare push while on trunk blocked" 2 "$on_trunk" 'git push'
run_case "push to main allowed when trunk is default" 0 "$trunk_feat" 'git push origin main'

# --- non-branch pushes and unrelated commands ---------------------------------
run_case "tags-only push allowed even on main" 0 "$on_main" 'git push origin --tags'
run_case "tag ref push allowed" 0 "$on_feat" 'git push origin refs/tags/v1.0.0'
run_case "upstream setup of feature branch allowed" 0 "$on_feat" 'git push -u origin feat/topic'
run_case "non-push command ignored" 0 "$on_main" 'git status'

# --- cross-repo form ----------------------------------------------------------
run_case "git -C repo-on-main bare push blocked from elsewhere" 2 "$on_feat" \
  "git -C $on_main push"

# --- git-level options before the subcommand ---------------------------------
# The detection regex tolerated only `-C <path>`; any other git-level option
# made it miss and the gate exit 0, publishing the default branch unchecked.
run_case "--no-pager push to main blocked" 2 "$on_feat" 'git --no-pager push origin main'
run_case "--git-dir push to main blocked" 2 "$on_feat" \
  'git --git-dir=.git --work-tree=. push origin main'
run_case "double-space push to main blocked" 2 "$on_feat" 'git  push origin main'
run_case "-c config push to main blocked" 2 "$on_feat" 'git -c core.pager=cat push origin main'
run_case "--no-pager bare push while on main blocked" 2 "$on_main" 'git --no-pager push'

# --- --follow-tags is not a tag-only push ------------------------------------
# It pushes the current branch plus reachable annotated tags. Exempting it as
# tag-only let a default-branch push skip this gate entirely.
run_case "--follow-tags while on main blocked" 2 "$on_main" 'git push --follow-tags'
run_case "--follow-tags with remote while on main blocked" 2 "$on_main" \
  'git push --follow-tags origin'
run_case "--follow-tags to main by refspec blocked" 2 "$on_feat" \
  'git push --follow-tags origin main'
run_case "--follow-tags on a feature branch allowed" 0 "$on_feat" 'git push --follow-tags'
run_case "--tags with a main refspec blocked" 2 "$on_feat" 'git push --tags origin main'

# --- every push on the line, not just the first ------------------------------
# Only one invocation used to be parsed: the greedy `.*` kept the last match on
# a line and `head -1` kept only the first matching line.
run_case "feature push then main push blocked" 2 "$on_feat" \
  'git push origin feat/topic && git push origin main'
run_case "main push then feature push blocked" 2 "$on_feat" \
  'git push -u origin main && git push origin feat/topic'
run_case "main push on a second line blocked" 2 "$on_feat" 'git push origin feat/topic
git push origin main'
run_case "main push after a semicolon blocked" 2 "$on_feat" \
  'git push origin feat/topic; git push origin main'
run_case "two feature pushes allowed" 0 "$on_feat" \
  'git push origin feat/topic && git push origin feat/other'
run_case "cross-repo second push to main blocked" 2 "$on_feat" \
  "git push origin feat/topic && git -C $on_main push"

# Bypass env var must allow the push through.
jq -n --arg cmd 'git push origin main' '{tool_input:{command:$cmd}}' \
  | (cd "$on_feat" && SKIP_PUSH_BRANCH_GATE=1 bash "$SUT") >/dev/null 2>&1
if [ $? -eq 0 ]; then
  echo "PASS: bypass env allows push (exit 0)"
  pass=$((pass + 1))
else
  echo "FAIL: bypass env allows push — expected exit 0"
  fail=$((fail + 1))
fi

rm -rf "$on_main" "$on_feat" "$on_trunk" "$trunk_feat"

echo ""
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
