#!/usr/bin/env bash
# Regression tests for hooks/pre-git-state-refresh.sh.
#
# Asserts on the additionalContext emitted (or the silence) for each command
# shape. A stubbed failing `gh` exercises the no-open-pr path without the
# network. Run: bash pre-git-state-refresh.test.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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
nowhere=$(mktemp -d)
out=$(payload 'git push' | (cd "$nowhere" && bash "$SUT") 2>/dev/null)
check "push outside a repo reports not-a-repo" "unavailable=not-a-repo" "$out"
rm -rf "$nowhere"

# git commit in a repo, with a stubbed gh that always fails -> no-open-pr.
repo=$(mktemp -d)
stub=$(mktemp -d)
printf '#!/bin/bash\nexit 1\n' > "$stub/gh"
chmod +x "$stub/gh"
(cd "$repo" && git init -q -b feat/x && git commit -q --allow-empty -m init)
out=$(payload 'git commit -m "feat: x"' | (cd "$repo" && PATH="$stub:$PATH" bash "$SUT") 2>/dev/null)
check "commit with no PR reports no-open-pr" "branch=feat/x no-open-pr" "$out"
rm -rf "$repo" "$stub"

echo ""
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
