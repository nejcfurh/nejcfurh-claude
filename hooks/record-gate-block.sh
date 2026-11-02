#!/usr/bin/env bash
# Internal helper: blocking gates call this right before exit 2 so the
# Stop-time retro nudge (retro-nudge.sh) can spot sessions with repeated gate
# friction. Records one line per block, keyed by session id, plus one dated
# line in a history log that is never pruned.
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

# The per-session files go after a week; this dated log does not, so /retro can
# see which gates fire across months and which never do.
history="${GATE_BLOCK_HISTORY_FILE:-$HOME/.claude/state/gate-block-history.tsv}"
mkdir -p "$(dirname "$history")" 2>/dev/null &&
  printf '%s\t%s\n' "$(date +%Y-%m-%d)" "$gate" >> "$history" 2>/dev/null

# Opportunistic cleanup: forget sessions older than a week.
find "$dir" -type f -mtime +7 -delete 2>/dev/null

exit 0
