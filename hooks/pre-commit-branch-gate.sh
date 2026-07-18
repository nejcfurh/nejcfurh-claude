#!/usr/bin/env bash
# PreToolUse (Bash, git commit): block commits made directly on main/master.
# Bypass: set SKIP_COMMIT_BRANCH_GATE to any non-empty value.

set -u

[ -n "${SKIP_COMMIT_BRANCH_GATE:-}" ] && exit 0
command -v jq >/dev/null 2>&1 || exit 0

payload=$(cat 2>/dev/null) || exit 0
[ -n "$payload" ] || exit 0

cmd=$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null) || exit 0
case "$cmd" in
  *"git commit"*) : ;;
  *) exit 0 ;;
esac

# Resolve the repo: cwd first, then the project dir.
repo=""
if git -C "$PWD" rev-parse --show-toplevel >/dev/null 2>&1; then
  repo="$PWD"
elif [ -n "${CLAUDE_PROJECT_DIR:-}" ] && git -C "$CLAUDE_PROJECT_DIR" rev-parse --show-toplevel >/dev/null 2>&1; then
  repo="$CLAUDE_PROJECT_DIR"
fi
[ -n "$repo" ] || exit 0

branch=$(git -C "$repo" branch --show-current 2>/dev/null)
case "$branch" in
  main|master)
    {
      echo "Blocked: commits directly to '$branch' are not allowed."
      echo "Create a feature branch first: git checkout -b <type>/<topic>"
      echo "Bypass: set SKIP_COMMIT_BRANCH_GATE=1"
    } >&2
    exit 2
    ;;
esac

exit 0
