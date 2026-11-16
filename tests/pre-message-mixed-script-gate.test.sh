#!/usr/bin/env bash
# Regression tests for hooks/pre-message-mixed-script-gate.sh — denies a message
# or draft whose text has a word mixing Latin with Cyrillic or Greek letters.
#
# Run: bash pre-message-mixed-script-gate.test.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="$SCRIPT_DIR/../hooks/pre-message-mixed-script-gate.sh"

work=$(mktemp -d "${TMPDIR:-/tmp}/hooktest-mixedscript.XXXXXX") || exit 1
export GATE_BLOCK_STATE_DIR="$work/state"
export GATE_BLOCK_HISTORY_FILE="$work/history.tsv"

pass=0
fail=0

payload() {
  jq -n --arg m "$1" '{session_id:"t1", tool_input:{channel_id:"D1", message:$m}}'
}

denies() {
  name="$1"
  out=$(payload "$2" | bash "$SUT" 2>/dev/null)
  if printf '%s' "$out" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1; then
    echo "PASS: denies — $name"
    pass=$((pass + 1))
  else
    echo "FAIL: denies — $name (output: ${out:0:80})"
    fail=$((fail + 1))
  fi
}

quiet() {
  name="$1"
  out=$(payload "$2" | bash "$SUT" 2>/dev/null)
  if [ -z "$out" ]; then
    echo "PASS: quiet — $name"
    pass=$((pass + 1))
  else
    echo "FAIL: quiet — $name (output: ${out:0:80})"
    fail=$((fail + 1))
  fi
}

denies "Cyrillic a at the end of a Latin word" "a ti rat$(printf '\xd0\xb0') rebase ta teden?"
denies "Greek omicron inside an English word" "the deploy is d$(printf '\xce\xbf')ne"
quiet "plain English" "Can you rebase this week?"
quiet "Latin with diacritics" "še mam 1v1, tak da začnem pol popoldan"
quiet "a whole Cyrillic word next to Latin words" "the word привет means hello"
quiet "a Greek unit after digits" "a 5μm filter"
quiet "an ohm unit" "a 10kΩ resistor"

out=$(payload "a ti rat$(printf '\xd0\xb0') rebase" | SKIP_MIXED_SCRIPT_GATE=1 bash "$SUT" 2>/dev/null)
if [ -z "$out" ]; then
  echo "PASS: bypass env skips the gate"
  pass=$((pass + 1))
else
  echo "FAIL: bypass env skips the gate"
  fail=$((fail + 1))
fi

rm -rf "$work"
echo "pre-message-mixed-script-gate: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
