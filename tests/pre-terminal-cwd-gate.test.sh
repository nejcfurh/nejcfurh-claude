#!/usr/bin/env bash
# Regression tests for hooks/pre-terminal-cwd-gate.sh — denies a terminal-tab
# call that names no cwd when the session works in a linked git worktree.
#
# Run: bash pre-terminal-cwd-gate.test.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="$SCRIPT_DIR/../hooks/pre-terminal-cwd-gate.sh"

work=$(mktemp -d "${TMPDIR:-/tmp}/hooktest-termcwd.XXXXXX") || exit 1
cd "$work" || exit 1
export GATE_BLOCK_STATE_DIR="$work/state"
export GATE_BLOCK_HISTORY_FILE="$work/history.tsv"

main="$work/main"
linked="$work/linked"
plain="$work/plain"
git init -q "$main"
git -C "$main" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
git -C "$main" worktree add -q -b side "$linked"
mkdir -p "$linked/sub" "$plain"

pass=0
fail=0

payload() {
  local here="$1" target="$2"
  if [ "$target" = "absent" ]; then
    jq -n --arg h "$here" '{session_id:"t1", cwd:$h, tool_input:{command:"pnpm test"}}'
  else
    jq -n --arg h "$here" --arg t "$target" '{session_id:"t1", cwd:$h, tool_input:{command:"pnpm test", cwd:$t}}'
  fi
}

denies() {
  local name="$1" out
  out=$(payload "$2" "$3" | bash "$SUT" 2>/dev/null)
  if printf '%s' "$out" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1; then
    echo "PASS: denies — $name"
    pass=$((pass + 1))
  else
    echo "FAIL: denies — $name (output: ${out:0:80})"
    fail=$((fail + 1))
  fi
}

quiet() {
  local name="$1" out rc
  out=$(payload "$2" "$3" | bash "$SUT" 2>/dev/null)
  rc=$?
  if [ -z "$out" ] && [ "$rc" = "0" ]; then
    echo "PASS: quiet — $name"
    pass=$((pass + 1))
  else
    echo "FAIL: quiet — $name (unexpected output: ${out:0:80})"
    fail=$((fail + 1))
  fi
}

denies "linked worktree, no cwd" "$linked" absent
denies "subfolder of a linked worktree, no cwd" "$linked/sub" absent
denies "linked worktree, empty cwd" "$linked" ""

out=$(payload "$linked" absent | bash "$SUT" 2>/dev/null)
if printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason' | grep -qF "$(cd "$linked" && pwd -P)"; then
  echo "PASS: the reason names the worktree's top folder"
  pass=$((pass + 1))
else
  echo "FAIL: the reason names the worktree's top folder"
  fail=$((fail + 1))
fi

if grep -q "pre-terminal-cwd-gate" "$GATE_BLOCK_HISTORY_FILE" 2>/dev/null; then
  echo "PASS: a block is recorded in the gate history"
  pass=$((pass + 1))
else
  echo "FAIL: a block is recorded in the gate history"
  fail=$((fail + 1))
fi

quiet "linked worktree, cwd given" "$linked" "$linked"
quiet "main checkout, no cwd" "$main" absent
quiet "not a repository, no cwd" "$plain" absent
quiet "session folder missing" "$work/gone" absent
SKIP_TERMINAL_CWD_GATE=1 quiet "SKIP env silences the gate" "$linked" absent

echo
echo "passed: $pass, failed: $fail"
[ "$fail" -eq 0 ] || exit 1
