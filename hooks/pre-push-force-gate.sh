#!/usr/bin/env bash
# PreToolUse (Bash, git push): block bare force pushes (--force / -f) in ANY
# command form. Permission-rule globs only catch the literal prefix
# `git push --force …` — not `git push origin main --force`, `git -C … push -f`,
# or force pushes buried in compound commands. --force-with-lease stays allowed
# (the /rebase flow depends on it); force pushes to the default branch are
# already blocked by pre-push-branch-gate.sh regardless of flags.
# Bypass: set SKIP_PUSH_FORCE_GATE to any non-empty value.

set -u

[ -n "${SKIP_PUSH_FORCE_GATE:-}" ] && exit 0
command -v jq >/dev/null 2>&1 || exit 0

payload=$(cat 2>/dev/null) || exit 0
[ -n "$payload" ] || exit 0

cmd=$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null) || exit 0

# Match `git push …` and `git -C <path> push …`.
printf '%s\n' "$cmd" | grep -Eq "git[[:space:]]+(-C[[:space:]]+(\"[^\"]*\"|'[^']*'|[^[:space:]]+)[[:space:]]+)?push([[:space:]]|\$)" || exit 0

# Arguments of the push invocation: everything after the first `push`, cut at
# the next command separator (same pragmatic parse as pre-push-branch-gate.sh).
rest="${cmd#*push}"
rest=$(printf '%s\n' "$rest" | head -1 | sed 's/[;&|].*//')

for tok in $rest; do
  case "$tok" in
    --force|-f)
      "$(dirname "$0")/record-gate-block.sh" "pre-push-force-gate" "$payload" 2>/dev/null || true
      {
        echo "Blocked: bare force push ('$tok') is never allowed."
        echo "If the remote must be overwritten, use --force-with-lease — and only"
        echo "after asking the user immediately before the push."
        echo "Bypass (human-only): '!'-prefix the command, or export SKIP_PUSH_FORCE_GATE=1 in your shell."
      } >&2
      exit 2
      ;;
  esac
done

exit 0
