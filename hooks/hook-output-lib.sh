#!/usr/bin/env bash
# Shared output helper for non-blocking warning hooks. Source it; do not run it.
#
# A hook that exits 0 with plain stdout is shown only in the transcript. Only
# SessionStart and UserPromptSubmit feed plain stdout into the model's context,
# so a PreToolUse warning printed with `cat`/`echo` reaches the user's verbose
# view and never the model it is written for. The warning has to travel in the
# JSON envelope as additionalContext.

# hook_warn <event> — reads the warning text on stdin and prints it as that
# event's additionalContext. Without jq it falls back to plain text, which is
# the old, transcript-only behaviour rather than silence.
hook_warn() {
  local event="$1" msg
  msg=$(cat)
  [ -n "$msg" ] || return 0
  if command -v jq >/dev/null 2>&1; then
    jq -cn --arg e "$event" --arg c "$msg" \
      '{hookSpecificOutput:{hookEventName:$e,additionalContext:$c}}'
  else
    printf '%s\n' "$msg"
  fi
}
