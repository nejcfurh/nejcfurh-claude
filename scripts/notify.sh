#!/usr/bin/env bash
# macOS desktop notification utility.
# Usage: notify.sh "<message>" ["<title>"]   (title defaults to "Claude Code")
# Suppressed when the frontmost app is already a terminal or editor.

set -u

msg="${1:-}"
title="${2:-Claude Code}"

[ -n "$msg" ] || exit 0
command -v osascript >/dev/null 2>&1 || exit 0

front=$(osascript -e 'tell application "System Events" to get name of first application process whose frontmost is true' 2>/dev/null) || front=""
case "$front" in
  Terminal|iTerm2|Ghostty|kitty|WezTerm|wezterm-gui|Alacritty|Code|Cursor) exit 0 ;;
esac

osascript \
  -e 'on run argv' \
  -e 'display notification (item 1 of argv) with title (item 2 of argv)' \
  -e 'end run' \
  "$msg" "$title" >/dev/null 2>&1 || true

exit 0
