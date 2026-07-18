#!/usr/bin/env bash
# SessionStart: verify that the ~/.claude config entries are symlinks pointing
# into the config repo; warn (never block) when any have drifted or are missing.

set -u

repo="${CLAUDE_CONFIG_REPO:-$HOME/Desktop/WebDev/Projects/nejcfurh-claude}"

# Canonicalize a path (best effort; falls back to the raw path).
resolve() {
  if command -v realpath >/dev/null 2>&1; then
    realpath "$1" 2>/dev/null
  elif command -v perl >/dev/null 2>&1; then
    perl -MCwd=abs_path -le 'print abs_path($ARGV[0])' "$1" 2>/dev/null
  else
    printf '%s\n' "$1"
  fi
}

drifted=""
for item in CLAUDE.md settings.json rules skills agents commands hooks scripts; do
  link="$HOME/.claude/$item"
  expected="$repo/$item"
  ok=0
  if [ -L "$link" ]; then
    actual=$(resolve "$link")
    want=$(resolve "$expected")
    if [ -n "$actual" ] && [ "$actual" = "$want" ]; then
      ok=1
    fi
  fi
  [ "$ok" -eq 1 ] || drifted="$drifted $item"
done

if [ -n "$drifted" ]; then
  echo "[symlink-check] ~/.claude entries drifted or missing:$drifted -- fix with: bash $repo/scripts/setup.sh"
fi

exit 0
