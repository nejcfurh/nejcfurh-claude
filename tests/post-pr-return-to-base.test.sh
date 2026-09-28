#!/usr/bin/env bash
# Regression tests for hooks/post-pr-return-to-base.sh — the PostToolUse hook
# that moves a checkout back to the PR's base branch after `gh pr create`.
# Each case runs against a throwaway upstream+clone pair, a stubbed `gh` that
# reports the PR, and a throwaway HOME (the config repo is located through it).
# Run: bash post-pr-return-to-base.test.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# A failed mktemp must never leak this suite's git commands into the real repo.
cd "$(mktemp -d "${TMPDIR:-/tmp}/hooktest-cwd.XXXXXX")" || exit 1
SUT="$SCRIPT_DIR/../hooks/post-pr-return-to-base.sh"

pass=0
fail=0

export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@test
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@test
unset CLAUDE_CONFIG_REPO

check() { # check <name> <condition-result>
  local name="$1" rc="$2"
  if [ "$rc" -eq 0 ]; then
    echo "PASS: $name"
    pass=$((pass + 1))
  else
    echo "FAIL: $name"
    fail=$((fail + 1))
  fi
}

# -> sets $upstream, $clone, $home, $stub. The clone is on branch 'feat' with
# one commit of its own, and upstream main is one commit ahead of the clone's.
setup() {
  upstream=$(mktemp -d "${TMPDIR:-/tmp}/hooktest-up.XXXXXX")
  (cd "$upstream" && git init -q -b main \
    && echo one > file && git add file && git commit -q -m "chore: one")
  clone=$(mktemp -d "${TMPDIR:-/tmp}/hooktest-cl.XXXXXX")
  rmdir "$clone"
  git clone -q "$upstream" "$clone"
  (cd "$clone" && git checkout -q -b feat \
    && echo feat > feat && git add feat && git commit -q -m "feat: x")
  (cd "$upstream" && echo two >> file && git commit -q -am "chore: two")
  home=$(mktemp -d "${TMPDIR:-/tmp}/hooktest-home.XXXXXX")
  stub=$(mktemp -d "${TMPDIR:-/tmp}/hooktest-stub.XXXXXX")
  stub_pr '{"number":7,"state":"OPEN","baseRefName":"main","headRefName":"feat"}'
}

stub_pr() { # stub_pr <json> — gh prints it and logs each call
  printf '#!/bin/bash\necho call >> "%s/calls"\ncat <<"JSON"\n%s\nJSON\n' "$stub" "$1" > "$stub/gh"
  chmod +x "$stub/gh"
}

stub_gh_fails() {
  printf '#!/bin/bash\necho call >> "%s/calls"\nexit 1\n' "$stub" > "$stub/gh"
  chmod +x "$stub/gh"
}

teardown() { rm -rf "$upstream" "$clone" "$home" "$stub"; }

run_hook() { # run_hook <cwd> [command] — runs from an unrelated process cwd
  local cwd="$1" cmd="${2:-gh pr create --fill}"
  jq -n --arg cmd "$cmd" --arg cwd "$cwd" '{tool_input:{command:$cmd},cwd:$cwd}' \
    | (cd "$home" && HOME="$home" PATH="$stub:$PATH" bash "$SUT")
}

branch_of() { git -C "$1" symbolic-ref --short HEAD; }
gh_calls() { [ -f "$stub/calls" ] && wc -l < "$stub/calls" | tr -d ' ' || echo 0; }

# Open PR, clean tree -> back on main, fast-forwarded to upstream.
setup
out=$(run_hook "$clone")
[ "$(branch_of "$clone")" = "main" ] && rc=0 || rc=1
check "open PR on a clean tree switches to the base branch (said: ${out:-<silent>})" "$rc"
[ "$(git -C "$clone" rev-parse HEAD)" = "$(git -C "$upstream" rev-parse main)" ] && rc=0 || rc=1
check "base branch is fast-forwarded to its upstream" "$rc"
case "$out" in *'"additionalContext"'*"PR #7"*"fast-forwarded"*"git switch feat"*) rc=0 ;; *) rc=1 ;; esac
check "the model is told where it is and how to get back" "$rc"
teardown

# Uncommitted changes -> stays on the branch and says why.
setup
echo local >> "$clone/feat"
out=$(run_hook "$clone")
[ "$(branch_of "$clone")" = "feat" ] && rc=0 || rc=1
check "dirty tree stays on the PR branch" "$rc"
case "$out" in *"uncommitted changes"*) rc=0 ;; *) rc=1 ;; esac
check "dirty tree gets a notice (said: ${out:-<silent>})" "$rc"
teardown

# Linked worktree -> left on its branch, silently.
setup
git -C "$clone" checkout -q main
wt="$clone-wt"
git -C "$clone" worktree add -q "$wt" feat
out=$(run_hook "$wt")
{ [ "$(branch_of "$wt")" = "feat" ] && [ -z "$out" ]; } && rc=0 || rc=1
check "linked worktree is left on its branch (said: ${out:-<silent>})" "$rc"
git -C "$clone" worktree remove --force "$wt"
teardown

# gh reports a PR whose head is another branch (`gh pr create --head other`).
setup
stub_pr '{"number":8,"state":"OPEN","baseRefName":"main","headRefName":"other"}'
out=$(run_hook "$clone" "gh pr create --head other --fill")
{ [ "$(branch_of "$clone")" = "feat" ] && [ -z "$out" ]; } && rc=0 || rc=1
check "PR for a different head branch does not move the checkout" "$rc"
teardown

# No PR for the branch (the create failed) -> nothing happens.
setup
stub_gh_fails
out=$(run_hook "$clone")
{ [ "$(branch_of "$clone")" = "feat" ] && [ -z "$out" ]; } && rc=0 || rc=1
check "failed create (no PR found) leaves the checkout alone" "$rc"
teardown

# A closed or merged PR is not a fresh create.
setup
stub_pr '{"number":7,"state":"MERGED","baseRefName":"main","headRefName":"feat"}'
out=$(run_hook "$clone")
[ "$(branch_of "$clone")" = "feat" ] && rc=0 || rc=1
check "non-open PR leaves the checkout alone" "$rc"
teardown

# Other gh commands never reach gh.
setup
out=$(run_hook "$clone" "gh pr view --json state")
{ [ "$(branch_of "$clone")" = "feat" ] && [ "$(gh_calls)" = "0" ]; } && rc=0 || rc=1
check "gh pr view neither moves the checkout nor calls gh" "$rc"
teardown

# Config repo -> switched, but the pull is left to the session-start sync.
setup
mkdir -p "$home/.claude"
echo rules > "$clone/CLAUDE.md"
git -C "$clone" add CLAUDE.md && git -C "$clone" commit -q -m "docs: rules"
ln -s "$clone/CLAUDE.md" "$home/.claude/CLAUDE.md"
before=$(git -C "$clone" rev-parse main)
out=$(run_hook "$clone")
[ "$(branch_of "$clone")" = "main" ] && rc=0 || rc=1
check "config repo is switched to its base branch" "$rc"
{ [ "$(git -C "$clone" rev-parse HEAD)" = "$before" ] \
  && case "$out" in *"Not pulled"*) true ;; *) false ;; esac; } && rc=0 || rc=1
check "config repo is not pulled (said: ${out:-<silent>})" "$rc"
teardown

# Local base branch diverged from upstream -> switched, not merged, and said so.
setup
(cd "$clone" && git checkout -q main && echo mine > mine && git add mine \
  && git commit -q -m "chore: local only" && git checkout -q feat)
before=$(git -C "$clone" rev-parse main)
out=$(run_hook "$clone")
{ [ "$(branch_of "$clone")" = "main" ] && [ "$(git -C "$clone" rev-parse HEAD)" = "$before" ]; } && rc=0 || rc=1
check "diverged base is switched to but not merged" "$rc"
case "$out" in *"could not fast-forward"*) rc=0 ;; *) rc=1 ;; esac
check "diverged base gets a notice (said: ${out:-<silent>})" "$rc"
teardown

# The trigger words as data, not a command: the branch already has an open PR,
# so a substring match would move the checkout on any of these.
ignores_as_data() { # ignores_as_data <command> <label>
  setup
  run_hook "$clone" "$1" >/dev/null
  { [ "$(branch_of "$clone")" = "feat" ] && [ "$(gh_calls)" = "0" ]; } && rc=0 || rc=1
  check "$2 is not a create" "$rc"
  teardown
}
ignores_as_data 'gh pr comment 7 --body "next: gh pr create for the follow-up"' "quoted --body text"
ignores_as_data "gh pr edit 7 --title 'gh pr create flow'" "single-quoted title"
ignores_as_data 'echo gh pr create' "echo argument"
ignores_as_data 'gh pr view 7; gh pr checks 7' "other gh pr subcommands"

# A create chained after a push still counts.
setup
out=$(run_hook "$clone" "git push -u origin feat && gh pr create --fill")
[ "$(branch_of "$clone")" = "main" ] && rc=0 || rc=1
check "create chained after a push switches (said: ${out:-<silent>})" "$rc"
teardown

# Wrappers and env prefixes before the create still count.
setup
run_hook "$clone" "GH_PROMPT_DISABLED=1 command gh pr create --fill" >/dev/null
[ "$(branch_of "$clone")" = "main" ] && rc=0 || rc=1
check "env-prefixed create switches" "$rc"
teardown

echo ""
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
