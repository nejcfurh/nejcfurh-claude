#!/usr/bin/env bash
# PreToolUse (Bash, git push): run every quality script the project defines
# (lint, typecheck, test, build - in that order) and block on the first failure.
# Bypass: set SKIP_PUSH_GATE to any non-empty value.

set -u

[ -n "${SKIP_PUSH_GATE:-}" ] && exit 0
command -v jq >/dev/null 2>&1 || exit 0

payload=$(cat 2>/dev/null) || exit 0
[ -n "$payload" ] || exit 0

cmd=$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null) || exit 0
case "$cmd" in
  *"git push"*) : ;;
  *) exit 0 ;;
esac

# Nearest package.json walking up (stop at $HOME or /), from $PWD
# then falling back to $CLAUDE_PROJECT_DIR.
find_pkg_dir() {
  d="$1"
  while :; do
    if [ -f "$d/package.json" ]; then printf '%s\n' "$d"; return 0; fi
    [ "$d" = "/" ] && break
    [ "$d" = "$HOME" ] && break
    d=$(dirname "$d")
  done
  return 1
}

pkg_dir=$(find_pkg_dir "$PWD")
if [ -z "$pkg_dir" ] && [ -n "${CLAUDE_PROJECT_DIR:-}" ]; then
  pkg_dir=$(find_pkg_dir "$CLAUDE_PROJECT_DIR")
fi
[ -n "$pkg_dir" ] || exit 0

# Package manager from the nearest lockfile, walking up (stop at $HOME or /).
pm="npm"
d="$pkg_dir"
while :; do
  if [ -f "$d/bun.lock" ] || [ -f "$d/bun.lockb" ]; then pm="bun"; break; fi
  if [ -f "$d/pnpm-lock.yaml" ]; then pm="pnpm"; break; fi
  if [ -f "$d/yarn.lock" ]; then pm="yarn"; break; fi
  [ "$d" = "/" ] && break
  [ "$d" = "$HOME" ] && break
  d=$(dirname "$d")
done

for step in lint typecheck test build; do
  jq -e --arg n "$step" '.scripts[$n]' "$pkg_dir/package.json" >/dev/null 2>&1 || continue
  out=$(cd "$pkg_dir" && CI=true $pm run "$step" 2>&1)
  if [ $? -ne 0 ]; then
    {
      echo "Push blocked: '$step' failed."
      echo "Command: CI=true $pm run $step (run in $pkg_dir)"
      echo ""
      printf '%s\n' "$out" | tail -n 40
      echo ""
      echo "Fix the failures above before pushing."
      echo "Bypass: set SKIP_PUSH_GATE=1"
    } >&2
    exit 2
  fi
done

exit 0
