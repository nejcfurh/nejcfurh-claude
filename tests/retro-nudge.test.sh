#!/usr/bin/env bash
# Regression tests for hooks/record-gate-block.sh + hooks/retro-nudge.sh.
#
# Gates record blocks per session; the Stop hook nudges once when the count
# reaches the threshold. Run: bash retro-nudge.test.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# A failed mktemp must never leak this suite's git commands into the real repo.
cd "$(mktemp -d "${TMPDIR:-/tmp}/hooktest-cwd.XXXXXX")" || exit 1
RECORD="$SCRIPT_DIR/../hooks/record-gate-block.sh"
NUDGE="$SCRIPT_DIR/../hooks/retro-nudge.sh"

pass=0
fail=0

check() { # check <name> <command…> — passes when the command exits 0
  local name="$1"
  shift
  if "$@"; then
    echo "PASS: $name"
    pass=$((pass + 1))
  else
    echo "FAIL: $name"
    fail=$((fail + 1))
  fi
}

state=$(mktemp -d "${TMPDIR:-/tmp}/hooktest.XXXXXX")
export GATE_BLOCK_STATE_DIR="$state"

payload='{"session_id":"sess-abc123","tool_input":{"command":"git push"}}'

# Recording with a session id appends one line per block.
bash "$RECORD" "gate-a" "$payload"
bash "$RECORD" "gate-a" "$payload"
bash "$RECORD" "gate-b" "$payload"
lines=$(wc -l < "$state/sess-abc123" | tr -d '[:space:]')
check "three blocks recorded" [ "$lines" = "3" ]

# No session id -> nothing recorded (test payloads, headless edge cases).
bash "$RECORD" "gate-a" '{"tool_input":{"command":"git push"}}'
count=$(find "$state" -type f | wc -l | tr -d '[:space:]')
check "payload without session id records nothing" [ "$count" = "1" ]

# A session id that could escape the state dir records nothing.
bash "$RECORD" "gate-a" '{"session_id":"../evil","tool_input":{"command":"x"}}'
check "path-traversal session id rejected" [ ! -f "$state/../evil" ]

# Below threshold -> silent.
printf 'gate-a\n' > "$state/sess-quiet"
out=$(printf '%s' '{"session_id":"sess-quiet"}' | bash "$NUDGE")
check "below threshold stays silent" [ -z "$out" ]

# At threshold -> one systemMessage, then never again for that session.
out=$(printf '%s' '{"session_id":"sess-abc123"}' | bash "$NUDGE")
nudged() { printf '%s' "$out" | jq -e '.systemMessage | test("retro")' >/dev/null 2>&1; }
check "threshold reached emits /retro nudge" nudged

out=$(printf '%s' '{"session_id":"sess-abc123"}' | bash "$NUDGE")
check "nudge fires at most once per session" [ -z "$out" ]

# Threshold is configurable.
printf 'gate-a\n' > "$state/sess-one"
out=$(printf '%s' '{"session_id":"sess-one"}' | RETRO_NUDGE_THRESHOLD=1 bash "$NUDGE")
check "threshold override respected" nudged

rm -rf "$state"

echo ""
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
