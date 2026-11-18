#!/usr/bin/env bash
# Regression tests for hooks/pre-message-pronoun-gate.sh — warns, never blocks,
# when a gh publish command, its body file, or a message/ticket tool's input
# uses a gendered pronoun.
#
# Run: bash pre-message-pronoun-gate.test.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="$SCRIPT_DIR/../hooks/pre-message-pronoun-gate.sh"

work=$(mktemp -d "${TMPDIR:-/tmp}/hooktest-pronoun.XXXXXX") || exit 1
work=$(cd "$work" && pwd)

pass=0
fail=0

bash_payload() {
  jq -n --arg c "$1" --arg d "$work" '{tool_name:"Bash", cwd:$d, tool_input:{command:$c}}'
}

mcp_payload() {
  jq -n --arg b "$1" '{tool_name:"mcp__linear__save_issue", tool_input:{team:"T", description:$b}}'
}

warns() {
  name="$1"
  out=$(printf '%s' "$2" | bash "$SUT" 2>/dev/null)
  if printf '%s' "$out" | jq -e '.hookSpecificOutput.additionalContext | test("\\[pronoun\\]")' >/dev/null 2>&1 &&
    ! printf '%s' "$out" | jq -e '.hookSpecificOutput.permissionDecision' >/dev/null 2>&1; then
    echo "PASS: warns — $name"
    pass=$((pass + 1))
  else
    echo "FAIL: warns — $name (output: ${out:0:80})"
    fail=$((fail + 1))
  fi
}

quiet() {
  name="$1"
  out=$(printf '%s' "$2" | bash "$SUT" 2>/dev/null)
  if [ -z "$out" ]; then
    echo "PASS: quiet — $name"
    pass=$((pass + 1))
  else
    echo "FAIL: quiet — $name (output: ${out:0:80})"
    fail=$((fail + 1))
  fi
}

printf 'A shopper who taps it expects to see her bag.\n' >"$work/body-her.md"
printf 'A shopper who taps it expects to see their bag.\n' >"$work/body-their.md"

warns "pronoun in a PR body file" "$(bash_payload 'gh pr create --base main --body-file body-her.md')"
warns "pronoun in a body file passed with =" "$(bash_payload 'gh pr edit 12 --body-file=body-her.md')"
warns "pronoun in a gh api body field" "$(bash_payload 'gh api --method PATCH repos/o/r/pulls/1 -F body=@body-her.md')"
warns "pronoun inline in a comment" "$(bash_payload 'gh pr comment 3 --body "He asked for this"')"
warns "pronoun in a ticket description" "$(mcp_payload 'The member lost his place in the list.')"
quiet "neutral PR body file" "$(bash_payload 'gh pr create --base main --body-file body-their.md')"
quiet "neutral ticket description" "$(mcp_payload 'The member lost their place in the list.')"
quiet "a gh command that publishes nothing" "$(bash_payload 'gh pr view 3 --json body')"
quiet "a non-gh command" "$(bash_payload 'echo she said')"
quiet "pronoun letters inside other words" "$(mcp_payload 'There is a theme and a hierarchy here; the shell helps.')"

out=$(printf '%s' "$(mcp_payload 'She asked')" | SKIP_PRONOUN_GATE=1 bash "$SUT" 2>/dev/null)
if [ -z "$out" ]; then
  echo "PASS: bypass env skips the gate"
  pass=$((pass + 1))
else
  echo "FAIL: bypass env skips the gate"
  fail=$((fail + 1))
fi

rm -rf "$work"
echo "pre-message-pronoun-gate: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
