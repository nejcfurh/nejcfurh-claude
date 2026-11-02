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

# Cases that do not set their own history file still must not touch the real one.
hist_default=$(fresh_dir)
export GATE_BLOCK_HISTORY_FILE="$hist_default/history.tsv"

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

# --- history -------------------------------------------------------------------
# One dated line per block, in a log the weekly cleanup never prunes — /retro
# reads it to see which gates fire across months.
hdir=$(fresh_dir)
h="$hdir/history.tsv"
record_h() { # record_h <gate> <payload>
  GATE_BLOCK_HISTORY_FILE="$h" GATE_BLOCK_STATE_DIR="$hdir/state" bash "$SUT" "$1" "$2" >/dev/null 2>&1
}
record_h pre-push-gate "$(payload sess-h)"
record_h pre-merge-gate "$(payload sess-h)"
check "history gets one line per block" "2" "$(wc -l < "$h" | tr -d ' ')"
check "history line is date, tab, gate" "$(date +%Y-%m-%d)	pre-push-gate" "$(head -1 "$h")"

record_h some-gate '{"tool_input":{"command":"git commit"}}'
record_h some-gate "$(payload '../escape')"
check "a block without a usable session adds no history" "2" "$(wc -l < "$h" | tr -d ' ')"

# With the default paths, a week-old history must survive the cleanup that
# prunes week-old session files.
fake_home="$hdir/home"
record_default() { # record_default <session>
  env -u GATE_BLOCK_HISTORY_FILE -u GATE_BLOCK_STATE_DIR HOME="$fake_home" \
    bash "$SUT" pre-push-gate "$(payload "$1")" >/dev/null 2>&1
}
record_default sess-d1
default_h="$fake_home/.claude/state/gate-block-history.tsv"
check "default history lives under ~/.claude/state" "1" "$(wc -l < "$default_h" | tr -d ' ')"
touch -t 202601010000 "$default_h" "$fake_home/.claude/state/gate-blocks/sess-d1"
record_default sess-d2
check "week-old session file is pruned" "0" \
  "$(find "$fake_home/.claude/state/gate-blocks" -name sess-d1 | wc -l | tr -d ' ')"
check "week-old history survives the cleanup" "2" "$(wc -l < "$default_h" | tr -d ' ')"

nested="$hdir/new/deeper/history.tsv"
GATE_BLOCK_HISTORY_FILE="$nested" GATE_BLOCK_STATE_DIR="$hdir/state" \
  bash "$SUT" pre-push-gate "$(payload sess-h3)"
check "missing history dir is created" "1" "$(wc -l < "$nested" | tr -d ' ')"

rm -rf "$dir" "$dir2" "$dir3" "$dir4" "$dir5" "$hdir" "$hist_default"

echo ""
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
