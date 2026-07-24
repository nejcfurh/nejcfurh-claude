#!/usr/bin/env bash
# Regression tests for hooks/pre-git-state-refresh.sh.
#
# Asserts on the additionalContext emitted (or the silence) for each command
# shape. A stubbed failing `gh` exercises the no-open-pr path without the
# network. Run: bash pre-git-state-refresh.test.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# A failed mktemp must never leak this suite's git commands into the real repo.
cd "$(mktemp -d "${TMPDIR:-/tmp}/hooktest-cwd.XXXXXX")" || exit 1
SUT="$SCRIPT_DIR/../hooks/pre-git-state-refresh.sh"

pass=0
fail=0

export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@test
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@test
unset CLAUDE_PROJECT_DIR

check() { # check <name> <expected-substring-or-EMPTY> <actual-output>
  local name="$1" expected="$2" out="$3" ctx
  if [ "$expected" = "EMPTY" ]; then
    if [ -z "$out" ]; then
      echo "PASS: $name (no output)"
      pass=$((pass + 1))
    else
      echo "FAIL: $name — expected no output, got: $out"
      fail=$((fail + 1))
    fi
    return
  fi
  ctx=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null)
  case "$ctx" in
    *"$expected"*)
      echo "PASS: $name ($ctx)"
      pass=$((pass + 1))
      ;;
    *)
      echo "FAIL: $name — expected context containing '$expected', got: $ctx"
      fail=$((fail + 1))
      ;;
  esac
}

payload() { # payload <command-string>
  jq -n --arg cmd "$1" '{tool_input:{command:$cmd}}'
}

# Non-PR-related commands must produce NO output and NO API call.
out=$(payload 'ls -la' | bash "$SUT" 2>/dev/null)
check "unrelated command stays silent" EMPTY "$out"

out=$(payload 'cat README.md' | bash "$SUT" 2>/dev/null)
check "read command stays silent" EMPTY "$out"

# git push outside any repo -> not-a-repo marker.
nowhere=$(mktemp -d "${TMPDIR:-/tmp}/hooktest.XXXXXX")
out=$(payload 'git push' | (cd "$nowhere" && bash "$SUT") 2>/dev/null)
check "push outside a repo reports not-a-repo" "unavailable=not-a-repo" "$out"
rm -rf "$nowhere"

# git commit in a repo, with a stubbed gh that always fails -> no-open-pr.
repo=$(mktemp -d "${TMPDIR:-/tmp}/hooktest.XXXXXX")
stub=$(mktemp -d "${TMPDIR:-/tmp}/hooktest.XXXXXX")
cache=$(mktemp -d "${TMPDIR:-/tmp}/hooktest.XXXXXX")
printf '#!/bin/bash\nexit 1\n' > "$stub/gh"
chmod +x "$stub/gh"
(cd "$repo" && git init -q -b feat/x && git commit -q --allow-empty -m init)
out=$(payload 'git commit -m "feat: x"' \
  | (cd "$repo" && PATH="$stub:$PATH" PR_STATE_CACHE_DIR="$cache" bash "$SUT") 2>/dev/null)
check "commit with no PR reports no-open-pr" "branch=feat/x no-open-pr" "$out"
rm -rf "$repo" "$stub" "$cache"

# --- the ~60s cache: one GitHub round-trip per repo+branch, not one per call --
repo=$(mktemp -d "${TMPDIR:-/tmp}/hooktest.XXXXXX")
stub=$(mktemp -d "${TMPDIR:-/tmp}/hooktest.XXXXXX")
cache=$(mktemp -d "${TMPDIR:-/tmp}/hooktest.XXXXXX")
counter="$stub/calls"
printf '#!/bin/bash\necho x >> "%s"\nexit 1\n' "$counter" > "$stub/gh"
chmod +x "$stub/gh"
(cd "$repo" && git init -q -b feat/x && git commit -q --allow-empty -m init)

out=$(payload 'git push' \
  | (cd "$repo" && PATH="$stub:$PATH" PR_STATE_CACHE_DIR="$cache" bash "$SUT") 2>/dev/null)
check "first lookup queries gh" "no-open-pr" "$out"

out=$(payload 'git push' \
  | (cd "$repo" && PATH="$stub:$PATH" PR_STATE_CACHE_DIR="$cache" bash "$SUT") 2>/dev/null)
check "cached lookup still emits the context line" "no-open-pr" "$out"

calls=$(wc -l < "$counter" | tr -d '[:space:]')
if [ "$calls" = "1" ]; then
  echo "PASS: second lookup served from cache (1 gh call)"
  pass=$((pass + 1))
else
  echo "FAIL: second lookup served from cache — expected 1 gh call, got $calls"
  fail=$((fail + 1))
fi

# A stale cache entry must refetch.
touch -t 202601010000 "$cache"/* 2>/dev/null
out=$(payload 'git push' \
  | (cd "$repo" && PATH="$stub:$PATH" PR_STATE_CACHE_DIR="$cache" bash "$SUT") 2>/dev/null)
check "stale cache still emits the context line" "no-open-pr" "$out"
calls=$(wc -l < "$counter" | tr -d '[:space:]')
if [ "$calls" = "2" ]; then
  echo "PASS: stale cache refetches (2 gh calls)"
  pass=$((pass + 1))
else
  echo "FAIL: stale cache refetches — expected 2 gh calls, got $calls"
  fail=$((fail + 1))
fi
rm -rf "$repo" "$stub" "$cache"

# --- direct gh-pr wiring resolves the checkout from payload.cwd -------------
# Wired directly for `gh pr *`, this hook is not moved to the Bash tool's
# checkout by the dispatcher. It must resolve the repo from payload.cwd, not
# the process cwd — otherwise a worktree gh-pr flow reports the wrong branch's
# PR. Start the hook in a repo on `main`, point payload.cwd at a second repo on
# `feat/worktree`, and assert the emitted branch is the payload.cwd one.
wrongrepo=$(mktemp -d "${TMPDIR:-/tmp}/hooktest.XXXXXX")
rightrepo=$(mktemp -d "${TMPDIR:-/tmp}/hooktest.XXXXXX")
stub=$(mktemp -d "${TMPDIR:-/tmp}/hooktest.XXXXXX")
cache=$(mktemp -d "${TMPDIR:-/tmp}/hooktest.XXXXXX")
printf '#!/bin/bash\nexit 1\n' > "$stub/gh"
chmod +x "$stub/gh"
(cd "$wrongrepo" && git init -q -b main && git commit -q --allow-empty -m init)
(cd "$rightrepo" && git init -q -b feat/worktree && git commit -q --allow-empty -m init)
out=$(jq -n --arg cmd 'gh pr view' --arg cwd "$rightrepo" \
    '{tool_input:{command:$cmd},cwd:$cwd}' \
  | (cd "$wrongrepo" && PATH="$stub:$PATH" PR_STATE_CACHE_DIR="$cache" bash "$SUT") 2>/dev/null)
check "gh pr resolves branch from payload.cwd, not the process cwd" \
  "branch=feat/worktree no-open-pr" "$out"
rm -rf "$wrongrepo" "$rightrepo" "$stub" "$cache"

echo ""
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
