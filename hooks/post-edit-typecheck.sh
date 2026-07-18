#!/usr/bin/env bash
# PostToolUse (Write|Edit): after a .ts/.tsx file changes, run the project's
# typecheck (script or bare tsc), then lint. Blocks (exit 2) on failures.
# Bypass: set SKIP_POST_EDIT_TYPECHECK to any non-empty value.

set -u

[ -n "${SKIP_POST_EDIT_TYPECHECK:-}" ] && exit 0
command -v jq >/dev/null 2>&1 || exit 0

payload=$(cat 2>/dev/null) || exit 0
[ -n "$payload" ] || exit 0

file=$(printf '%s' "$payload" | jq -r '.tool_input.file_path // empty' 2>/dev/null) || exit 0
[ -n "$file" ] || exit 0

case "$file" in
  *.ts|*.tsx) : ;;
  *) exit 0 ;;
esac

start_dir=$(cd "$(dirname "$file")" 2>/dev/null && pwd) || exit 0

# Nearest package.json, walking up (stop at $HOME or /).
pkg_dir=""
d="$start_dir"
while :; do
  if [ -f "$d/package.json" ]; then pkg_dir="$d"; break; fi
  [ "$d" = "/" ] && break
  [ "$d" = "$HOME" ] && break
  d=$(dirname "$d")
done
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

has_script() {
  jq -e --arg n "$1" '.scripts[$n]' "$pkg_dir/package.json" >/dev/null 2>&1
}

# --- typecheck ---------------------------------------------------------------
tc_cmd=""
if has_script typecheck; then
  tc_cmd="$pm run typecheck"
elif [ -f "$pkg_dir/tsconfig.json" ]; then
  tc_cmd="npx --no-install tsc --noEmit"
else
  exit 0
fi

out=$(cd "$pkg_dir" && $tc_cmd 2>&1)
if [ $? -ne 0 ]; then
  {
    echo "Typecheck failed after editing: $file"
    echo "Command: $tc_cmd (run in $pkg_dir)"
    echo ""
    printf '%s\n' "$out" | tail -n 40
    echo ""
    echo "Fix the type errors above before continuing."
    echo "Bypass: set SKIP_POST_EDIT_TYPECHECK=1"
  } >&2
  exit 2
fi

# --- lint --------------------------------------------------------------------
if has_script "lint:fix"; then
  ( cd "$pkg_dir" && $pm run lint:fix ) >/dev/null 2>&1 || true
elif has_script lint; then
  out=$(cd "$pkg_dir" && $pm run lint 2>&1)
  if [ $? -ne 0 ]; then
    {
      echo "Lint failed after editing: $file"
      echo "Command: $pm run lint (run in $pkg_dir)"
      echo ""
      printf '%s\n' "$out" | tail -n 40
      echo ""
      echo "Fix the lint errors above before continuing."
      echo "Bypass: set SKIP_POST_EDIT_TYPECHECK=1"
    } >&2
    exit 2
  fi
fi

exit 0
