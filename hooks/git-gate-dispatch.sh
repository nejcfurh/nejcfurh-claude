#!/usr/bin/env bash
# PreToolUse (Bash, git *): single entry point for every git-command gate.
# Reads the payload once and routes by subcommand, so a plain `git status`
# costs one process instead of ten. The gates stay separate scripts — each
# keeps its own regression suite and SKIP_* bypass; only the wiring and
# ordering live here.
#
# Routing is deliberately loose (substring, not exact match): the gates do
# the precise `git … push|commit` parsing themselves, including `git -C`
# and `cd <path> &&` forms — this only skips gates that cannot possibly
# match. pre-git-state-refresh runs LAST and only when nothing blocked: its
# stdout is a JSON context envelope that must not be mixed with gate output,
# and a blocked command should not pay its GitHub API round-trip.

set -u

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

payload=$(cat 2>/dev/null) || exit 0
[ -n "$payload" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

cmd=$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null) || exit 0
[ -n "$cmd" ] || exit 0

run_gate() {
  gate="$HOOK_DIR/$1"
  [ -x "$gate" ] || return 0
  printf '%s' "$payload" | "$gate"
  rc=$?
  [ "$rc" -eq 2 ] && exit 2
  return 0
}

case "$cmd" in
  *push*)
    run_gate pre-push-branch-gate.sh
    run_gate pre-push-force-gate.sh
    run_gate pre-push-verify-gate.sh
    run_gate pre-push-author-gate.sh
    run_gate pre-push-gate.sh
    ;;
esac

case "$cmd" in
  *commit*)
    run_gate pre-commit-branch-gate.sh
    run_gate pre-commit-coauthor-gate.sh
    run_gate pre-commit-conventional-gate.sh
    run_gate pre-commit-secret-gate.sh
    ;;
esac

run_gate pre-git-state-refresh.sh

exit 0
