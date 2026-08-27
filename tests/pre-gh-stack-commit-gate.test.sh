#!/usr/bin/env bash
# Regression tests for hooks/pre-gh-stack-commit-gate.sh — refuses to let
# `gh stack init|add` stage and commit in one step.
#
# Why the gate exists: such a commit is real, but its command line contains no
# `commit` substring, so git-gate-dispatch.sh never routes it to the branch,
# co-author, conventional-message and secret gates. The block is what keeps the
# content coming through `git commit`, where those fire.
#
# The quiet cases matter as much as the blocking ones: `gh stack` is also how
# branches, submits and views happen, and a gate that fires on those makes the
# whole extension unusable. The flag scan runs on a copy with quoted spans
# blanked, so a branch name or subject that merely contains something
# flag-shaped is not mistaken for a flag.
# Run: bash pre-gh-stack-commit-gate.test.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="$SCRIPT_DIR/../hooks/pre-gh-stack-commit-gate.sh"

pass=0
fail=0

command -v jq >/dev/null 2>&1 || {
  echo "SKIP: jq is required to build payloads"
  exit 0
}

# blocks <name> <command> — expects exit 2 and an explanation on stderr
blocks() {
  local name="$1" command="$2" out rc
  out=$(jq -n --arg cmd "$command" '{tool_input:{command:$cmd}}' | bash "$SUT" 2>&1)
  rc=$?
  if [ "$rc" = "2" ] && [ -n "$out" ]; then
    echo "PASS: blocks — $name"
    pass=$((pass + 1))
  else
    echo "FAIL: blocks — $name (rc=$rc)"
    fail=$((fail + 1))
  fi
}

# quiet <name> <command> — expects exit 0 and total silence
quiet() {
  local name="$1" command="$2" out rc
  out=$(jq -n --arg cmd "$command" '{tool_input:{command:$cmd}}' | bash "$SUT" 2>&1)
  rc=$?
  if [ "$rc" = "0" ] && [ -z "$out" ]; then
    echo "PASS: quiet — $name"
    pass=$((pass + 1))
  else
    echo "FAIL: quiet — $name (rc=$rc, output: ${out:-none})"
    fail=$((fail + 1))
  fi
}

# --- blocks: gh stack is being asked to commit --------------------------------
blocks "add -A -m" 'gh stack add -A -m "feat(api): add endpoint"'
blocks "add -m alone" 'gh stack add -m "feat(api): add endpoint"'
blocks "add -Am bundled" 'gh stack add -Am "feat(api): add endpoint"'
blocks "add --message" 'gh stack add --message "feat(api): add endpoint"'
blocks "add --message=x" 'gh stack add --message="feat(api): add endpoint"'
blocks "init -A -m" 'gh stack init --base main -A -m "chore(deps): bump"'
blocks "amend -m" 'gh stack amend -m "fix(api): typo"'
blocks "extra whitespace between words" 'gh   stack   add   -A   -m   "feat: x"'

# --- quiet: staging without committing ----------------------------------------
# -A/-u only stage. The `git commit` that has to follow them reaches every commit
# gate on its own, so blocking these would be friction with no safety return.
quiet "add -A with no message" 'gh stack add -A slice-two'
quiet "add --all with no message" 'gh stack add --all slice-two'
quiet "add -u with no message" 'gh stack add -u slice-two'
quiet "add -a with no message" 'gh stack add -a slice-two'

# --- quiet: topology, submission and inspection -------------------------------
quiet "add a branch, nothing else" 'gh stack add oauth-schema'
quiet "init with a base" 'gh stack init --base main oauth-schema'
quiet "submit" 'gh stack submit --auto --open'
quiet "view json" 'gh stack view --json'
quiet "sync" 'gh stack sync'
quiet "rebase" 'gh stack rebase'
quiet "up" 'gh stack up'
quiet "long flags that are not --all/--message" 'gh stack add --draft --base main slice'

# --- quiet: something flag-shaped that is not a flag --------------------------
quiet "branch name containing -a-" 'gh stack add feat/add-a-provider'
quiet "branch name containing -m-" 'gh stack add fix/add-m-flag-docs'
quiet "quoted subject mentioning -m" 'gh stack view --json "notes about -m usage"'

# --- blocks: still reached when it is not the first command --------------------
blocks "after a && separator" 'cd /repo && gh stack add -A -m "feat(api): add endpoint"'
blocks "after a semicolon" 'set -e; gh stack add -m "feat(api): add endpoint"'
blocks "behind an env prefix" 'GIT_AUTHOR_NAME=x gh stack add -m "feat(api): add endpoint"'

# --- quiet: the command merely mentioned, not invoked --------------------------
# The gate's own first firing was on a commit message describing it, so the scan
# is anchored to command position, runs after here-doc bodies are dropped, and
# attributes a -m only to the command it sits on.
quiet "prose in a here-doc body" 'git commit -F - <<EOF
feat(hooks): gate gh stack commits

gh stack add accepts -m, which commits behind the gates.
EOF'
quiet "quoted mention" 'echo "never run gh stack add -m subject"'
quiet "-m belongs to a different command" 'gh stack add slice-two && git commit -m "feat(api): add endpoint"'
quiet "-m belongs to git, gh stack only viewed" 'gh stack view; git commit -m "feat(api): add endpoint"'

# --- quiet: not gh stack at all -----------------------------------------------
quiet "plain git commit" 'git commit -m "feat(api): add endpoint"'
quiet "gh pr create" 'gh pr create --fill'
quiet "gh stack in prose, not a command" 'echo "use gh stack add later"'

# --- bypass -------------------------------------------------------------------
out=$(jq -n --arg cmd 'gh stack add -A -m "feat: x"' '{tool_input:{command:$cmd}}' |
  SKIP_GH_STACK_COMMIT_GATE=1 bash "$SUT" 2>&1)
rc=$?
if [ "$rc" = "0" ] && [ -z "$out" ]; then
  echo "PASS: quiet — SKIP env silences the gate"
  pass=$((pass + 1))
else
  echo "FAIL: quiet — SKIP env silences the gate (rc=$rc)"
  fail=$((fail + 1))
fi

# --- malformed input fails open -----------------------------------------------
out=$(printf '' | bash "$SUT" 2>&1)
rc=$?
if [ "$rc" = "0" ] && [ -z "$out" ]; then
  echo "PASS: quiet — empty payload"
  pass=$((pass + 1))
else
  echo "FAIL: quiet — empty payload (rc=$rc)"
  fail=$((fail + 1))
fi

echo
echo "passed: $pass, failed: $fail"
[ "$fail" -eq 0 ] || exit 1
