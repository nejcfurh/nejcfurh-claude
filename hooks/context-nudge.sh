#!/usr/bin/env bash
# Stop hook: when the conversation's context usage crosses a threshold
# (default 50% of the window), surface a one-time suggestion to /handoff or
# start a fresh session — long contexts slow every response and degrade
# output quality, and by the time it is obvious it is usually too late to
# hand off cheaply.
#
# Context size is read from the transcript: the prompt-token usage of the
# last main-chain assistant message (input + cache reads + cache writes).
# The window size is NOT in the transcript — default 200000; sessions on a
# 1M-context model should export CONTEXT_WINDOW_TOKENS=1000000 (settings
# env or settings.local.json). Threshold override: CONTEXT_NUDGE_PERCENT.

set -u

command -v jq >/dev/null 2>&1 || exit 0

payload=$(cat 2>/dev/null) || exit 0
[ -n "$payload" ] || exit 0

session=$(printf '%s' "$payload" | jq -r '.session_id // empty' 2>/dev/null) || exit 0
[ -n "$session" ] || exit 0
# The session id becomes a filename — refuse anything that could escape the dir.
case "$session" in *[!A-Za-z0-9_-]*) exit 0 ;; esac

dir="${CONTEXT_NUDGE_STATE_DIR:-$HOME/.claude/state/context-nudge}"
# Nudge at most once per session.
[ -f "$dir/$session" ] && exit 0

tp=$(printf '%s' "$payload" | jq -r '.transcript_path // empty' 2>/dev/null) || exit 0
[ -n "$tp" ] && [ -f "$tp" ] || exit 0

# Only the tail matters and transcripts grow to many MB. Sidechain
# (subagent) entries carry their own, smaller usage — skip them or a
# subagent finishing last would mask the real context size.
tokens=$(tail -n 200 "$tp" 2>/dev/null | jq -r '
  select(.isSidechain != true) | .message.usage | select(. != null)
  | (.input_tokens // 0) + (.cache_read_input_tokens // 0) + (.cache_creation_input_tokens // 0)
' 2>/dev/null | tail -n 1)
[ -n "$tokens" ] || exit 0
case "$tokens" in *[!0-9]*) exit 0 ;; esac

window="${CONTEXT_WINDOW_TOKENS:-200000}"
threshold="${CONTEXT_NUDGE_PERCENT:-50}"
case "$window" in ''|*[!0-9]*) exit 0 ;; esac
case "$threshold" in ''|*[!0-9]*) exit 0 ;; esac
[ "$window" -gt 0 ] || exit 0

pct=$((tokens * 100 / window))
[ "$pct" -ge "$threshold" ] || exit 0

mkdir -p "$dir" 2>/dev/null && : >"$dir/$session"
# Opportunistic cleanup: forget sessions older than a week.
find "$dir" -type f -mtime +7 -delete 2>/dev/null

jq -cn --arg msg "Context is at ~${pct}% of the ${window}-token window (${tokens} tokens). Consider /handoff into a fresh session — long contexts slow every response and degrade quality. (Set CONTEXT_WINDOW_TOKENS if this session's window is not ${window}.)" \
  '{systemMessage: $msg}'
exit 0
