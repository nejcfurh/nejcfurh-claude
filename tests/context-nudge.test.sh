#!/usr/bin/env bash
# Regression tests for hooks/context-nudge.sh.
#
# Each case feeds a Stop payload pointing at a crafted transcript and asserts
# on the emitted systemMessage (or the silence). State and thresholds are
# fully overridden via env, so the suite never touches real session state.
# Run: bash context-nudge.test.sh
set -u

# This repo exports CONTEXT_WINDOW_TOKENS in its own session env (so the nudge
# hook honors the 1M window). That value would leak into the cases below that
# rely on the hook's built-in defaults; clear both inherited vars so each case
# sees either the default or its own inline override.
unset CONTEXT_WINDOW_TOKENS CONTEXT_NUDGE_PERCENT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# A failed mktemp must never leak this suite's git commands into the real repo.
cd "$(mktemp -d "${TMPDIR:-/tmp}/hooktest-cwd.XXXXXX")" || exit 1
SUT="$SCRIPT_DIR/../hooks/context-nudge.sh"

pass=0
fail=0

check() { # check <name> <expected-substring-or-EMPTY> <actual-output>
  local name="$1" expected="$2" out="$3" msg
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
  msg=$(printf '%s' "$out" | jq -r '.systemMessage // ""' 2>/dev/null)
  case "$msg" in
    *"$expected"*)
      echo "PASS: $name"
      pass=$((pass + 1))
      ;;
    *)
      echo "FAIL: $name — expected message containing '$expected', got: $msg"
      fail=$((fail + 1))
      ;;
  esac
}

payload() { # payload <session-id> <transcript-path>
  jq -n --arg sid "$1" --arg tp "$2" '{session_id:$sid, transcript_path:$tp}'
}

usage_line() { # usage_line <input> <cache-read> <cache-creation>
  jq -cn --argjson i "$1" --argjson r "$2" --argjson c "$3" \
    '{type:"assistant", message:{usage:{input_tokens:$i, cache_read_input_tokens:$r, cache_creation_input_tokens:$c, output_tokens:10}}}'
}

work=$(mktemp -d "${TMPDIR:-/tmp}/hooktest.XXXXXX")
state="$work/state"

# 40k of 200k = 20% — below the 50% default.
low="$work/low.jsonl"
usage_line 1000 38000 1000 > "$low"
out=$(payload sess-low "$low" | CONTEXT_NUDGE_STATE_DIR="$state" bash "$SUT" 2>/dev/null)
check "below threshold stays silent" EMPTY "$out"

# 120k of 200k = 60% — nudges, and the message names the percentage.
high="$work/high.jsonl"
{
  usage_line 1000 38000 1000
  usage_line 2000 115000 3000
} > "$high"
out=$(payload sess-high "$high" | CONTEXT_NUDGE_STATE_DIR="$state" bash "$SUT" 2>/dev/null)
check "above threshold nudges with percentage" "60%" "$out"
out=$(payload sess-high "$high" | CONTEXT_NUDGE_STATE_DIR="$state" bash "$SUT" 2>/dev/null)
check "nudge fires at most once per session" EMPTY "$out"

out=$(payload sess-high2 "$high" | CONTEXT_NUDGE_STATE_DIR="$state" bash "$SUT" 2>/dev/null)
check "message suggests /handoff" "/handoff" "$out"

# Cache fields must be summed — a session running on cache reads alone still counts.
cached="$work/cached.jsonl"
usage_line 0 130000 0 > "$cached"
out=$(payload sess-cached "$cached" | CONTEXT_NUDGE_STATE_DIR="$state" bash "$SUT" 2>/dev/null)
check "cache-read-only usage still counted" "65%" "$out"

# The LAST main-chain entry wins; a sidechain (subagent) entry finishing last
# must not mask the real context size.
side="$work/side.jsonl"
{
  usage_line 2000 115000 3000
  jq -cn '{isSidechain:true, type:"assistant", message:{usage:{input_tokens:500, cache_read_input_tokens:0, cache_creation_input_tokens:0, output_tokens:5}}}'
} > "$side"
out=$(payload sess-side "$side" | CONTEXT_NUDGE_STATE_DIR="$state" bash "$SUT" 2>/dev/null)
check "sidechain usage ignored" "60%" "$out"

# Window override: 120k of 1M is 12% — silent.
out=$(payload sess-window "$high" | CONTEXT_NUDGE_STATE_DIR="$state" CONTEXT_WINDOW_TOKENS=1000000 bash "$SUT" 2>/dev/null)
check "window override respected" EMPTY "$out"

# Threshold override: 20% usage nudges at a 10% threshold.
out=$(payload sess-thresh "$low" | CONTEXT_NUDGE_STATE_DIR="$state" CONTEXT_NUDGE_PERCENT=10 bash "$SUT" 2>/dev/null)
check "threshold override respected" "20%" "$out"

# Defensive paths: missing transcript, hostile session id.
out=$(payload sess-missing "$work/does-not-exist.jsonl" | CONTEXT_NUDGE_STATE_DIR="$state" bash "$SUT" 2>/dev/null)
check "missing transcript stays silent" EMPTY "$out"

out=$(payload '../../etc/passwd' "$high" | CONTEXT_NUDGE_STATE_DIR="$state" bash "$SUT" 2>/dev/null)
check "path-traversal session id rejected" EMPTY "$out"

rm -rf "$work"

echo ""
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
