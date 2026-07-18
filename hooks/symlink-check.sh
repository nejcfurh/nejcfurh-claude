#!/usr/bin/env bash
# SessionStart: verify that the ~/.claude config entries are symlinks pointing
# into the config repo; warn (never block) when any have drifted or are missing.

set -u

# Locate the config repo through the CLAUDE.md symlink itself — a hardcoded
# clone path would break the "clone anywhere, run setup" install story. When
# even CLAUDE.md is not linked, nothing can be verified against a repo; warn
# about that directly instead of guessing a path.
repo="${CLAUDE_CONFIG_REPO:-}"
if [ -z "$repo" ] && [ -L "$HOME/.claude/CLAUDE.md" ]; then
  link_target=$(readlink "$HOME/.claude/CLAUDE.md")
  case "$link_target" in
    /*) repo=$(dirname "$link_target") ;;
  esac
fi
if [ -z "$repo" ]; then
  echo "[symlink-check] ~/.claude/CLAUDE.md is not a symlink into the config repo -- run scripts/setup.sh from your clone of nejcfurh-claude."
  exit 0
fi

# Every git gate parses its payload with jq and fails OPEN without it: a
# machine missing jq has the whole enforcement layer silently disabled.
if ! command -v jq >/dev/null 2>&1; then
  echo "[symlink-check] jq is NOT installed -- every git quality gate is silently disabled. Install it now: brew install jq"
fi

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
# Keep in sync with ITEMS in scripts/setup.sh — lint-config.sh enforces it.
ITEMS="CLAUDE.md settings.json rules skills agents hooks scripts"
for item in $ITEMS; do
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
