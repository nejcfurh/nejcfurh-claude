#!/usr/bin/env bash
# Stop hook: as the conversation's context usage crosses each of several
# thresholds (default 50%, 75% and 90% of the window), surface a suggestion to
# /handoff or start a fresh session — long contexts slow every response and
# degrade output quality, and by the time it is obvious it is usually too late
# to hand off cheaply.
#
# One nudge per session is not enough, and the transcripts on this machine are
# why: across 48 sessions the median peak was 281k tokens, 18 ran past 500k and
# five came within 5% of a 1M window. A session that goes 500k -> 950k under a
# single-shot nudge is warned once, at the point where handing off is still
# cheap, and then runs in silence through the whole half where it is not.
#
# Each tier fires at most once, so the escalation stays proportional instead of
# repeating every turn — the state file records the highest tier reached rather
# than the bare fact that something fired.
#
# Context size is read from the transcript: the prompt-token usage of the
# last main-chain assistant message (input + cache reads + cache writes).
# The window size is NOT in the transcript — default 200000; sessions on a
# 1M-context model should set CONTEXT_WINDOW_TOKENS=1000000 in the `env` block of
# ~/.claude/settings.json. NOT settings.local.json: Claude Code reads that variant
# at project scope only, so a value put there is silently ignored and this hook
# nudges at 100k — 10% of the real window. Thresholds: CONTEXT_NUDGE_PERCENT,
# a comma-separated list ("50,75,90"); a single value still means a single tier.

set -u

command -v jq >/dev/null 2>&1 || exit 0

payload=$(cat 2>/dev/null) || exit 0
[ -n "$payload" ] || exit 0

session=$(printf '%s' "$payload" | jq -r '.session_id // empty' 2>/dev/null) || exit 0
[ -n "$session" ] || exit 0
# The session id becomes a filename — refuse anything that could escape the dir.
case "$session" in *[!A-Za-z0-9_-]*) exit 0 ;; esac

dir="${CONTEXT_NUDGE_STATE_DIR:-$HOME/.claude/state/context-nudge}"

# Tiers, ascending or not — only the highest one at or below the current usage
# matters, so the list never needs sorting.
tiers="${CONTEXT_NUDGE_PERCENT:-50,75,90}"
top=-1
for t in ${tiers//,/ }; do
  case "$t" in '' | *[!0-9]*) continue ;; esac
  [ "$t" -gt "$top" ] && top=$t
done
[ "$top" -ge 0 ] || exit 0

# Highest tier this session has already fired. A legacy state file from the
# single-shot version is empty and reads as -1, so a session live across the
# upgrade re-nudges once rather than going silent for good.
last=-1
if [ -f "$dir/$session" ]; then
  last=$(cat "$dir/$session" 2>/dev/null) || last=-1
  case "$last" in '' | *[!0-9]*) last=-1 ;; esac
fi

# Every tier is spent — skip the transcript read entirely, as the single-shot
# version did once it had fired.
[ "$last" -ge "$top" ] && exit 0

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
case "$window" in ''|*[!0-9]*) exit 0 ;; esac
[ "$window" -gt 0 ] || exit 0

pct=$((tokens * 100 / window))

# The highest tier this usage has reached. Only a tier above the last one fired
# nudges, so a session sitting at 60% goes quiet until it reaches 75%.
reached=-1
for t in ${tiers//,/ }; do
  case "$t" in '' | *[!0-9]*) continue ;; esac
  if [ "$pct" -ge "$t" ] && [ "$t" -gt "$reached" ]; then reached=$t; fi
done
[ "$reached" -ge 0 ] || exit 0
[ "$reached" -gt "$last" ] || exit 0

mkdir -p "$dir" 2>/dev/null && printf '%s' "$reached" >"$dir/$session"
# Opportunistic cleanup: forget sessions older than a week.
find "$dir" -type f -mtime +7 -delete 2>/dev/null

# Tone tracks the usage, not the tier index, so a custom tier list still reads
# sensibly. Every tier names /handoff — it is the action in all three cases.
if [ "$pct" -ge 90 ]; then
  advice="Hand off NOW — /handoff into a fresh session. This close to the ceiling a compact is imminent, and whatever it drops is chosen for you rather than by you."
elif [ "$pct" -ge 75 ]; then
  advice="Wrap up the current step and /handoff — past three quarters the window costs more per turn than the work left in it is usually worth."
else
  advice="Consider /handoff into a fresh session — long contexts slow every response and degrade quality."
fi

jq -cn --arg msg "Context is at ~${pct}% of the ${window}-token window (${tokens} tokens). ${advice} (Set CONTEXT_WINDOW_TOKENS if this session's window is not ${window}.)" \
  '{systemMessage: $msg}'
exit 0
