#!/usr/bin/env bash
# PreToolUse (Bash, git commit): block AI attribution footers in commit messages.
# Bypass: set SKIP_COAUTHOR_GATE to any non-empty value.

set -u

[ -n "${SKIP_COAUTHOR_GATE:-}" ] && exit 0
command -v jq >/dev/null 2>&1 || exit 0

payload=$(cat 2>/dev/null) || exit 0
[ -n "$payload" ] || exit 0

cmd=$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null) || exit 0
# Match both `git commit …` and `git -C <path> commit …` — the -C form has no
# literal "git commit" substring and would otherwise bypass the gate.
if ! printf '%s\n' "$cmd" | grep -Eq "git[[:space:]]+-C[[:space:]]+(\"[^\"]*\"|'[^']*'|[^[:space:]]+)[[:space:]]+commit([[:space:]]|\$)"; then
  case "$cmd" in
    *"git commit"*) : ;;
    *) exit 0 ;;
  esac
fi

lower=$(printf '%s' "$cmd" | tr '[:upper:]' '[:lower:]')
case "$lower" in
  *"co-authored-by"*|*"generated with claude"*)
    {
      echo "Blocked: AI attribution is not allowed in this user's commits."
      echo "Rewrite the commit message without the 'Co-Authored-By' /"
      echo "'Generated with Claude' attribution footer and commit again."
      echo "Bypass (human-only): '!'-prefix the command, or export SKIP_COAUTHOR_GATE=1 in your shell."
    } >&2
    exit 2
    ;;
esac

exit 0
