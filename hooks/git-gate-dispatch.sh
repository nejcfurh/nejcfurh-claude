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

# Fail CLOSED without jq: every gate parses its payload with it, so a missing
# jq once meant the whole enforcement layer silently disabled (fail open).
# Block git commands instead — setup.sh makes jq a hard prerequisite, so this
# only fires if jq is later removed. Only git commands reach this hook.
if ! command -v jq >/dev/null 2>&1; then
  [ -n "${SKIP_GIT_GATE_NO_JQ:-}" ] && exit 0
  {
    echo "Blocked: git quality gates require jq, which is not installed."
    echo "Without jq the gates cannot parse the command, so git operations are"
    echo "blocked rather than run ungated. Fix: install jq (brew install jq)."
    echo "Bypass (human-only): export SKIP_GIT_GATE_NO_JQ=1 in your shell."
  } >&2
  exit 2
fi

cmd=$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null) || exit 0
[ -n "$cmd" ] || exit 0

# Gates fall back to $PWD when the command names no explicit target, but the
# hook process starts in the session's original project dir — not the checkout
# the Bash tool is actually in after a persisted `cd` (worktrees especially).
# The payload's cwd is that checkout; run every gate from there. A missing or
# vanished dir falls back to the hook's own cwd.
payload_cwd=$(printf '%s' "$payload" | jq -r '.cwd // empty' 2>/dev/null)
if [ -n "$payload_cwd" ] && [ -d "$payload_cwd" ]; then
  cd "$payload_cwd" 2>/dev/null || true
fi

run_gate() {
  gate="$HOOK_DIR/$1"
  [ -x "$gate" ] || return 0
  printf '%s' "$payload" | "$gate"
  rc=$?
  [ "$rc" -eq 2 ] && exit 2
  return 0
}

# Meta-execution surfaces (git -c / --exec-path / diff --no-index) escape the
# subcommand gates entirely — check every git command, before routing.
run_gate pre-git-meta-gate.sh

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
