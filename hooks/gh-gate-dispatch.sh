#!/usr/bin/env bash
# PreToolUse (Bash, gh *): single entry point for every gh-command gate, mirroring
# git-gate-dispatch.sh. Reads the payload once and routes by subcommand.
#
# Why this exists: the three gh gates were wired as three independent settings.json
# entries, so ordering was undefined and pre-git-state-refresh ran even when a gate
# had already blocked — `gh pr merge 999` was rejected AND still paid for a GitHub
# API round-trip whose JSON context envelope got mixed into the block output. The
# state refresh now runs LAST and only when nothing blocked, exactly as on the git
# path.
#
# Routing is deliberately loose (substring, not exact): every gate re-checks the
# command itself — pre-merge-gate.sh parses it with quoted spans blanked, and
# pre-pr-test-gate.sh guards on its own `gh pr create` match — so this only skips
# gates that cannot possibly apply. Matching here rather than with a settings.json
# `if` glob also covers bare `gh pr create` with no arguments, which the old
# `Bash(gh pr create *)` matcher required a trailing argument to see.

set -u

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

payload=$(cat 2>/dev/null) || exit 0
[ -n "$payload" ] || exit 0

# Unlike the git dispatcher this stays fail-OPEN without jq, matching what each gh
# gate already does on its own. The git path fails closed because it guards commit
# and push history; the gh path's blocking gate only stops PR merges, which the
# user performs manually anyway.
command -v jq >/dev/null 2>&1 || exit 0

cmd=$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null) || exit 0
[ -n "$cmd" ] || exit 0

# Gates fall back to $PWD when the command names no explicit target, but the hook
# process starts in the session's original project dir — not the checkout the Bash
# tool is actually in after a persisted `cd`. The payload's cwd is that checkout.
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

# Every gh command: the user merges PRs manually.
run_gate pre-merge-gate.sh

case "$cmd" in
  *"gh pr create"*) run_gate pre-pr-test-gate.sh ;;
esac

# `gh stack init|add` can stage and commit with -A/-m. That commit line contains
# no `commit` substring, so git-gate-dispatch.sh never routes it to the commit
# gates — this gate refuses the shortcut and sends the content back through
# `git commit`, where they fire.
case "$cmd" in
  *"gh stack"*) run_gate pre-gh-stack-commit-gate.sh ;;
esac

# Advisory, and last: its stdout is a JSON context envelope that must not be mixed
# with gate output, and a blocked command should not pay the API round-trip.
case "$cmd" in
  *"gh pr"*) run_gate pre-git-state-refresh.sh ;;
esac

exit 0
