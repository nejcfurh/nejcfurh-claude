#!/usr/bin/env bash
# Regression tests for hooks/pre-doc-full-rewrite-gate.sh — asks before a
# document tool's full-page rewrite, stays silent on every targeted command.
#
# The load-bearing cases are the ALLOWS: the gate sits on every page update, so
# a search-and-replace, an insert, a property change, a payload with no command
# and an empty payload all have to pass without a sound. The one BLOCK case must
# come back as an "ask" decision in the JSON envelope, not a bare exit code —
# a plain exit 2 would deny the rewrite outright, which is not the contract.
# Run: bash pre-doc-full-rewrite-gate.test.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="$SCRIPT_DIR/../hooks/pre-doc-full-rewrite-gate.sh"

pass=0
fail=0

command -v jq >/dev/null 2>&1 || {
  echo "SKIP: jq is required to build payloads"
  exit 0
}

call() {
  jq -n --arg cmd "$1" '{tool_name:"mcp__docs__update-page",tool_input:{page_id:"abc",command:$cmd,new_str:"# Title"}}'
}

# asks <name> <payload> — expects exit 0 and an "ask" decision with a reason
asks() {
  local name="$1" payload="$2" out rc decision reason
  out=$(printf '%s' "$payload" | bash "$SUT" 2>&1)
  rc=$?
  decision=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
  reason=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null)
  if [ "$rc" = "0" ] && [ "$decision" = "ask" ] && [ -n "$reason" ]; then
    echo "PASS: asks — $name"
    pass=$((pass + 1))
  else
    echo "FAIL: asks — $name (rc=$rc, output: ${out:-none})"
    fail=$((fail + 1))
  fi
}

# allows <name> <payload> — expects exit 0 and total silence
allows() {
  local name="$1" payload="$2" out rc
  out=$(printf '%s' "$payload" | bash "$SUT" 2>&1)
  rc=$?
  if [ "$rc" = "0" ] && [ -z "$out" ]; then
    echo "PASS: allows — $name"
    pass=$((pass + 1))
  else
    echo "FAIL: allows — $name (rc=$rc, output: ${out:-none})"
    fail=$((fail + 1))
  fi
}

# --- asks: the full-page rewrite ----------------------------------------------
asks "replace_content" "$(call replace_content)"
asks "replace_content with deletion allowed" \
  "$(jq -n '{tool_input:{page_id:"abc",command:"replace_content",new_str:"x",allow_deleting_content:true}}')"

# --- allows: targeted commands and degenerate payloads ------------------------
allows "update_content (search and replace)" "$(call update_content)"
allows "insert_content" "$(call insert_content)"
allows "update_properties" "$(call update_properties)"
allows "apply_template" "$(call apply_template)"
allows "payload without a command" "$(jq -n '{tool_input:{page_id:"abc"}}')"
allows "payload without tool_input" "$(jq -n '{tool_name:"mcp__docs__update-page"}')"
allows "empty payload" ""

# --- bypass -------------------------------------------------------------------
out=$(printf '%s' "$(call replace_content)" | SKIP_DOC_FULL_REWRITE_GATE=1 bash "$SUT" 2>&1)
rc=$?
if [ "$rc" = "0" ] && [ -z "$out" ]; then
  echo "PASS: allows — bypass variable set"
  pass=$((pass + 1))
else
  echo "FAIL: allows — bypass variable set (rc=$rc, output: ${out:-none})"
  fail=$((fail + 1))
fi

echo
echo "$pass passed, $fail failed"
[ "$fail" = "0" ]
