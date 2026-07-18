#!/usr/bin/env bash
# PreToolUse (Bash, gh pr create): run the project's test script before a PR
# is opened; block (exit 2) when tests fail.
# Bypass: set SKIP_PR_TEST_GATE to any non-empty value.

set -u

[ -n "${SKIP_PR_TEST_GATE:-}" ] && exit 0
command -v jq >/dev/null 2>&1 || exit 0

payload=$(cat 2>/dev/null) || exit 0
[ -n "$payload" ] || exit 0

cmd=$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null) || exit 0
case "$cmd" in
  *"gh pr create"*) : ;;
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

# No test script, or only the npm placeholder -> nothing to gate on.
test_script=$(jq -r '.scripts.test // ""' "$pkg_dir/package.json" 2>/dev/null)
[ -n "$test_script" ] || exit 0
case "$test_script" in
  *"no test specified"*) exit 0 ;;
esac

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

out=$(cd "$pkg_dir" && CI=true $pm run test 2>&1)
if [ $? -ne 0 ]; then
  "$(dirname "$0")/record-gate-block.sh" "pre-pr-test-gate" "$payload" 2>/dev/null || true
  {
    echo "Blocked: tests must pass before opening a PR."
    echo "Command: CI=true $pm run test (run in $pkg_dir)"
    echo ""
    printf '%s\n' "$out" | tail -n 40
    echo ""
    echo "Fix the failing tests, then create the PR again."
    echo "Bypass (human-only): '!'-prefix the command, or export SKIP_PR_TEST_GATE=1 in your shell."
  } >&2
  exit 2
fi

exit 0
