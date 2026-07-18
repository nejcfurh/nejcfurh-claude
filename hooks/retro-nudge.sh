#!/usr/bin/env bash
# Stop hook: when a session tripped >= RETRO_NUDGE_THRESHOLD quality-gate
# blocks (recorded by record-gate-block.sh), surface a one-time suggestion to
# run /retro — repeated gate friction means something is worth encoding into
# config instead of being re-corrected every session.

set -u

command -v jq >/dev/null 2>&1 || exit 0

payload=$(cat 2>/dev/null) || exit 0
[ -n "$payload" ] || exit 0

session=$(printf '%s' "$payload" | jq -r '.session_id // empty' 2>/dev/null) || exit 0
[ -n "$session" ] || exit 0
case "$session" in *[!A-Za-z0-9_-]*) exit 0 ;; esac

dir="${GATE_BLOCK_STATE_DIR:-$HOME/.claude/state/gate-blocks}"
file="$dir/$session"
[ -f "$file" ] || exit 0
# Nudge at most once per session.
[ -f "$file.nudged" ] && exit 0

threshold="${RETRO_NUDGE_THRESHOLD:-3}"
count=$(wc -l < "$file" | tr -d '[:space:]')
[ "$count" -ge "$threshold" ] 2>/dev/null || exit 0

: > "$file.nudged"
gates=$(sort "$file" | uniq -c | sort -rn | awk '{printf "%s%s x%s", sep, $2, $1; sep=", "}')
jq -cn --arg msg "Quality gates blocked $count operations this session ($gates). Consider running /retro to encode the fix so it stops recurring." \
  '{systemMessage: $msg}'
exit 0
