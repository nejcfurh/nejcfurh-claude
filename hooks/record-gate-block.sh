#!/usr/bin/env bash
# Internal helper: blocking gates call this right before exit 2 so the
# Stop-time retro nudge (retro-nudge.sh) can spot sessions with repeated gate
# friction. Records one line per block, keyed by session id.
# Usage: record-gate-block.sh <gate-name> <payload-json>
# Never fails the caller; records nothing when no session id is present.

set -u

gate="${1:-}"
payload="${2:-}"
[ -n "$gate" ] || exit 0
[ -n "$payload" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

session=$(printf '%s' "$payload" | jq -r '.session_id // empty' 2>/dev/null) || exit 0
[ -n "$session" ] || exit 0
# The session id becomes a filename — refuse anything that could escape the dir.
case "$session" in *[!A-Za-z0-9_-]*) exit 0 ;; esac

dir="${GATE_BLOCK_STATE_DIR:-$HOME/.claude/state/gate-blocks}"
mkdir -p "$dir" 2>/dev/null || exit 0
printf '%s\n' "$gate" >> "$dir/$session" 2>/dev/null || exit 0

# Opportunistic cleanup: forget sessions older than a week.
find "$dir" -type f -mtime +7 -delete 2>/dev/null

exit 0
