#!/usr/bin/env bash
# Regression tests for hooks/pre-bash-gh-sandbox-gate.sh — warns (never
# blocks) when `gh` runs INSIDE the sandbox, where it cannot read its own
# config and fails or returns nothing.
#
# Much of this suite asserts silence: gh outside the sandbox is correct, and
# "gh" inside another word or a path is not an invocation.
#
# Exit code is always 0.
# Run: bash pre-bash-gh-sandbox-gate.test.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

cd "$(mktemp -d "${TMPDIR:-/tmp}/hooktest-cwd.XXXXXX")" || exit 1
SUT="$SCRIPT_DIR/../hooks/pre-bash-gh-sandbox-gate.sh"

pass=0
fail=0

# is_context <output> — true when the hook spoke in the JSON envelope Claude
# Code feeds to the model. Plain stdout from a PreToolUse hook that exits 0 is
# shown only in the transcript, so a warning printed that way never reaches the
# model; "some output" is not enough to count as firing.
is_context() {
  printf '%s' "$1" | jq -e \
    '.hookSpecificOutput.hookEventName == "PreToolUse" and (.hookSpecificOutput.additionalContext | length > 0)' \
    >/dev/null 2>&1
}

payload() {
  local command="$1" unsandboxed="$2"
  if [ "$unsandboxed" = "absent" ]; then
    jq -n --arg cmd "$command" '{tool_input:{command:$cmd}}'
  else
    jq -n --arg cmd "$command" --argjson u "$unsandboxed" '{tool_input:{command:$cmd, dangerouslyDisableSandbox:$u}}'
  fi
}

# fires <name> <command> <unsandboxed> — expects advisory output AND exit 0
fires() {
  local name="$1" out rc
  out=$(payload "$2" "$3" | bash "$SUT" 2>/dev/null)
  rc=$?
  if is_context "$out" && [ "$rc" = "0" ]; then
    echo "PASS: fires — $name"
    pass=$((pass + 1))
  else
    echo "FAIL: fires — $name (output=${#out} chars, exit $rc; expected output and exit 0)"
    fail=$((fail + 1))
  fi
}

# quiet <name> <command> <unsandboxed> — expects no output at all
quiet() {
  local name="$1" out rc
  out=$(payload "$2" "$3" | bash "$SUT" 2>/dev/null)
  rc=$?
  if [ -z "$out" ] && [ "$rc" = "0" ]; then
    echo "PASS: quiet — $name"
    pass=$((pass + 1))
  else
    echo "FAIL: quiet — $name (unexpected output: ${out:0:60})"
    fail=$((fail + 1))
  fi
}

# --- fires: gh invoked inside the sandbox --------------------------------------
fires "gh at the start, sandbox flag false" 'gh pr list --state open' false
fires "gh at the start, sandbox flag absent" 'gh pr view 107 --json state' absent
fires "gh after cd &&" 'cd /repo && gh pr create --base main --body-file /abs/b.md' false
fires "gh after a pipe" 'echo x | gh api repos/o/r/pulls' false
fires "gh inside command substitution" 'n=$(gh pr list --json number --jq length)' false
fires "gh after a semicolon" 'git fetch; gh run list' false

# --- quiet: gh outside the sandbox, the correct form ---------------------------
quiet "unsandboxed gh" 'gh pr list --state open' true
quiet "unsandboxed gh after cd" 'cd /repo && gh pr view 1' true

# --- quiet: no gh invocation ---------------------------------------------------
quiet "gh inside a path" 'ls ~/.config/gh/ -la' false
quiet "gh inside a word" 'echo "high ground"' false
quiet "gh as an argument, not a command" 'git log --grep "gh stack"' false
quiet "plain git" 'git status -sb' false

# --- bypass ---------------------------------------------------------------------
SKIP_BASH_GH_SANDBOX_GATE=1 quiet "SKIP env silences the gate" 'gh pr list' false

echo
echo "passed: $pass, failed: $fail"
[ "$fail" -eq 0 ] || exit 1
