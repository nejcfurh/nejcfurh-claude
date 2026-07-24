#!/usr/bin/env bash
# Regression tests for hooks/record-gate-block.sh — the tally every blocking gate
# writes on its way to exit 2, and the only input retro-nudge.sh reads.
#
# It was the one hook with no suite. Nothing here can fail loudly in production
# either: the helper is called with `|| true` from gates that are already exiting,
# so a silent break would just mean the /retro nudge never fires again.
# Run: bash record-gate-block.test.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="$SCRIPT_DIR/../hooks/record-gate-block.sh"

cd "$(mktemp -d "${TMPDIR:-/tmp}/hooktest-cwd.XXXXXX")" || exit 1

pass=0
fail=0

check() { # check <name> <expected> <actual>
  if [ "$2" = "$3" ]; then
    echo "PASS: $1"
    pass=$((pass + 1))
  else
    echo "FAIL: $1 — expected '$2', got '$3'"
    fail=$((fail + 1))
  fi
}

payload() { # payload <session-id>
  jq -n --arg s "$1" '{session_id:$s, tool_input:{command:"git commit -m x"}}'
}

fresh_dir() { mktemp -d "${TMPDIR:-/tmp}/gateblocks.XXXXXX"; }

# --- the happy path ------------------------------------------------------------
dir=$(fresh_dir)
payload sess-1 | GATE_BLOCK_STATE_DIR="$dir" bash "$SUT" pre-commit-branch-gate "$(payload sess-1)"
check "records one line for the session" "1" "$(wc -l < "$dir/sess-1" | tr -d ' ')"
check "records the gate name" "pre-commit-branch-gate" "$(cat "$dir/sess-1")"

# Repeated blocks accumulate — retro-nudge counts lines to find friction.
for _ in 1 2 3; do
  GATE_BLOCK_STATE_DIR="$dir" bash "$SUT" pre-push-gate "$(payload sess-1)"
done
check "repeated blocks append" "4" "$(wc -l < "$dir/sess-1" | tr -d ' ')"

# Separate sessions are tallied separately.
GATE_BLOCK_STATE_DIR="$dir" bash "$SUT" pre-merge-gate "$(payload sess-2)"
check "a second session gets its own file" "1" "$(wc -l < "$dir/sess-2" | tr -d ' ')"

# The state dir is created on demand: a first-ever block must still record.
missing="$dir/nested/deeper"
GATE_BLOCK_STATE_DIR="$missing" bash "$SUT" pre-push-gate "$(payload sess-3)"
check "missing state dir is created" "1" "$(wc -l < "$missing/sess-3" | tr -d ' ')"

# --- refusals, all silent and non-fatal ---------------------------------------
rc_of() { # rc_of <args…> -> exit code, output discarded
  GATE_BLOCK_STATE_DIR="$1" bash "$SUT" "$2" "$3" >/dev/null 2>&1
  echo $?
}

dir2=$(fresh_dir)
check "no gate name exits 0"      "0" "$(rc_of "$dir2" "" "$(payload sess-x)")"
check "no payload exits 0"        "0" "$(rc_of "$dir2" "some-gate" "")"
check "malformed payload exits 0" "0" "$(rc_of "$dir2" "some-gate" "not json at all")"
check "payload without session exits 0" "0" \
  "$(rc_of "$dir2" "some-gate" '{"tool_input":{"command":"git commit"}}')"
check "nothing recorded for those" "0" "$(find "$dir2" -type f | wc -l | tr -d ' ')"

# A session id becomes a filename, so anything that could escape the directory is
# refused rather than sanitised.
dir3=$(fresh_dir)
for bad in "../escape" "a/b" "sess 1" 'sess;rm' '$(id)' "sess*"; do
  GATE_BLOCK_STATE_DIR="$dir3" bash "$SUT" some-gate "$(payload "$bad")" >/dev/null 2>&1
done
check "path-unsafe session ids record nothing" "0" "$(find "$dir3" -type f | wc -l | tr -d ' ')"
check "no file escaped the state dir" "0" \
  "$(find "$(dirname "$dir3")" -maxdepth 1 -name 'escape' | wc -l | tr -d ' ')"

# Ids that are legitimately filename-safe must still work.
dir4=$(fresh_dir)
GATE_BLOCK_STATE_DIR="$dir4" bash "$SUT" some-gate "$(payload 'abc-123_DEF')"
check "hyphens, underscores and digits are accepted" "1" \
  "$(wc -l < "$dir4/abc-123_DEF" | tr -d ' ')"

# --- retention -----------------------------------------------------------------
# Cleanup is opportunistic; a week-old tally goes, today's stays.
dir5=$(fresh_dir)
: > "$dir5/old-session"
touch -t 202601010000 "$dir5/old-session"
GATE_BLOCK_STATE_DIR="$dir5" bash "$SUT" some-gate "$(payload today-session)"
check "stale session file is pruned" "0" "$(find "$dir5" -name 'old-session' | wc -l | tr -d ' ')"
check "current session file survives" "1" "$(find "$dir5" -name 'today-session' | wc -l | tr -d ' ')"

rm -rf "$dir" "$dir2" "$dir3" "$dir4" "$dir5"

echo ""
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
