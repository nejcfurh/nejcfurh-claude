#!/usr/bin/env bash
# Regression tests for hooks/gh-gate-dispatch.sh — the single entry point for the
# gh-command gates.
#
# The finding it closes: the three gh gates were three independent settings.json
# entries, so pre-git-state-refresh ran even when a gate had already blocked. A
# rejected `gh pr merge` still paid a GitHub API round-trip and mixed its JSON
# context envelope into the block output. `gh` is stubbed so no case touches the
# network. Run: bash gh-gate-dispatch.test.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="$SCRIPT_DIR/../hooks/gh-gate-dispatch.sh"

cd "$(mktemp -d "${TMPDIR:-/tmp}/hooktest-cwd.XXXXXX")" || exit 1

pass=0
fail=0

export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@test
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@test
unset CLAUDE_PROJECT_DIR

check() { # check <name> <expected> <actual>
  if [ "$2" = "$3" ]; then
    echo "PASS: $1"
    pass=$((pass + 1))
  else
    echo "FAIL: $1 — expected '$2', got '$3'"
    fail=$((fail + 1))
  fi
}

# A gh that always fails keeps pre-git-state-refresh on its no-open-pr path
# without a network call — it still emits its context envelope, which is what the
# ordering assertions below look for.
stub=$(mktemp -d "${TMPDIR:-/tmp}/ghstub.XXXXXX")
printf '#!/bin/sh\nexit 1\n' > "$stub/gh"
chmod +x "$stub/gh"
export PATH="$stub:$PATH"

repo=$(mktemp -d "${TMPDIR:-/tmp}/hooktest.XXXXXX")
git init -q -b feat/x "$repo" >/dev/null 2>&1
git -C "$repo" commit -q --allow-empty -m "chore: init" >/dev/null 2>&1

# A repo whose tests fail, so the PR test gate has something to block on.
failrepo=$(mktemp -d "${TMPDIR:-/tmp}/hooktest.XXXXXX")
git init -q -b feat/x "$failrepo" >/dev/null 2>&1
git -C "$failrepo" commit -q --allow-empty -m "chore: init" >/dev/null 2>&1
printf '{"name":"f","scripts":{"test":"exit 1"}}' > "$failrepo/package.json"
touch "$failrepo/package-lock.json"

run() { # run <cwd> <command> -> "<rc>|<stdout>"
  local wd="$1" cmd="$2" out rc
  out=$(jq -n --arg c "$cmd" --arg w "$wd" '{tool_input:{command:$c},cwd:$w,session_id:"gh-disp"}' \
    | (cd "$wd" && bash "$SUT" 2>/dev/null))
  rc=$?
  printf '%s|%s' "$rc" "$out"
}

rc_of() { printf '%s' "${1%%|*}"; }
out_of() { printf '%s' "${1#*|}"; }

# --- the merge gate still blocks through the dispatcher ------------------------
r=$(run "$repo" 'gh pr merge 123 --squash')
check "gh pr merge blocked" "2" "$(rc_of "$r")"

r=$(run "$repo" 'git push origin feat/x && gh pr merge 123')
check "merge buried in a compound command blocked" "2" "$(rc_of "$r")"

r=$(run "$repo" 'gh api -X PUT repos/o/r/pulls/1/merge')
check "gh api merge endpoint blocked" "2" "$(rc_of "$r")"

# --- THE FINDING: a blocked command must not also emit the state envelope -----
r=$(run "$repo" 'gh pr merge 123 --squash')
case "$(out_of "$r")" in
  *"[pr-state]"*) got=emitted ;;
  *) got=absent ;;
esac
check "blocked merge does not pay for the state refresh" "absent" "$got"

# ...while an allowed gh pr command still gets it.
r=$(run "$repo" 'gh pr view 1')
check "gh pr view allowed" "0" "$(rc_of "$r")"
case "$(out_of "$r")" in
  *"[pr-state]"*) got=emitted ;;
  *) got=absent ;;
esac
check "allowed gh pr command still gets the state envelope" "emitted" "$got"

# --- the PR test gate, including the form the old if-glob missed ---------------
r=$(run "$failrepo" 'gh pr create --fill')
check "gh pr create with failing tests blocked" "2" "$(rc_of "$r")"

# `Bash(gh pr create *)` required a trailing argument, so bare `gh pr create`
# reached no gate at all. Matching inside the dispatcher covers it.
r=$(run "$failrepo" 'gh pr create')
check "bare gh pr create with failing tests blocked" "2" "$(rc_of "$r")"

r=$(run "$repo" 'gh pr create --fill')
check "gh pr create with no test script allowed" "0" "$(rc_of "$r")"

# --- commands that reach no gate ----------------------------------------------
r=$(run "$repo" 'gh issue list')
check "unrelated gh command allowed" "0" "$(rc_of "$r")"
case "$(out_of "$r")" in
  *"[pr-state]"*) got=emitted ;;
  *) got=absent ;;
esac
check "non-pr gh command skips the state refresh" "absent" "$got"

r=$(run "$repo" 'gh pr list')
check "gh pr list allowed" "0" "$(rc_of "$r")"

# --- degenerate payloads must never break the tool call ------------------------
check "empty payload exits 0" "0" "$(printf '' | bash "$SUT" >/dev/null 2>&1; echo $?)"
check "payload without a command exits 0" "0" \
  "$(printf '{"cwd":"/tmp"}' | bash "$SUT" >/dev/null 2>&1; echo $?)"
check "malformed payload exits 0" "0" \
  "$(printf 'not json' | bash "$SUT" >/dev/null 2>&1; echo $?)"

# A missing gate file is skipped, not fatal: run_gate tests for -x first.
tmphooks=$(mktemp -d "${TMPDIR:-/tmp}/hooks-partial.XXXXXX")
cp "$SUT" "$tmphooks/"
r=$(jq -n --arg c 'gh pr view 1' --arg w "$repo" '{tool_input:{command:$c},cwd:$w}' \
  | (cd "$repo" && bash "$tmphooks/gh-gate-dispatch.sh" >/dev/null 2>&1; echo $?))
check "missing gate files are skipped, not fatal" "0" "$r"

rm -rf "$repo" "$failrepo" "$stub" "$tmphooks"

echo ""
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
