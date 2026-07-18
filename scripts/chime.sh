#!/usr/bin/env bash
# Play a short completion chime — used by Stop/Notification hooks so long
# tasks are audible when you're in another app. Suppressed when a terminal
# or editor is frontmost (you're already looking at the session).
#
# Usage: chime.sh [volume]   (default 1.5)
# Sound override: CLAUDE_CHIME_SOUND=/System/Library/Sounds/Ping.aiff

VOLUME="${1:-1.5}"
SOUND="${CLAUDE_CHIME_SOUND:-/System/Library/Sounds/Glass.aiff}"

command -v afplay >/dev/null 2>&1 || exit 0
command -v osascript >/dev/null 2>&1 || exit 0
[ -f "$SOUND" ] || exit 0

front="$(osascript -e 'tell application "System Events" to get name of first application process whose frontmost is true' 2>/dev/null)"
case "$front" in
  Terminal|iTerm2|Ghostty|kitty|WezTerm|wezterm-gui|Alacritty|Code|Cursor)
    exit 0
    ;;
esac

afplay "$SOUND" -v "$VOLUME" >/dev/null 2>&1 &
exit 0
