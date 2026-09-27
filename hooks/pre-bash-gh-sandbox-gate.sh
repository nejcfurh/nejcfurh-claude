#!/usr/bin/env bash
# PreToolUse (Bash): warn when `gh` runs INSIDE the sandbox. gh keeps its
# login in a deny-read config file, so a sandboxed gh cannot start: depending
# on the subcommand it fails on "failed to read configuration", or prints
# nothing at all. Empty output is exactly what "no open PRs" or "no such
# branch" looks like, so the refusal reads as a finding.
#
# Warn-only: the right move is to re-run gh with the sandbox disabled, which
# is gh reading its own credentials, not a bypass of anything.
#
# Bypass: set SKIP_BASH_GH_SANDBOX_GATE to any non-empty value.

set -u

[ -n "${SKIP_BASH_GH_SANDBOX_GATE:-}" ] && exit 0

payload=$(cat 2>/dev/null) || exit 0
[ -n "$payload" ] || exit 0

# Runs on EVERY Bash call: bail on a builtin match before spending a jq.
case "$payload" in
  *gh\ *) : ;;
  *) exit 0 ;;
esac

command -v jq >/dev/null 2>&1 || exit 0

unsandboxed=$(printf '%s' "$payload" | jq -r '.tool_input.dangerouslyDisableSandbox // false' 2>/dev/null) || exit 0
[ "$unsandboxed" = "true" ] && exit 0

cmd=$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null) || exit 0
[ -n "$cmd" ] || exit 0

# gh as a command word: at the start, or after ; & | ( or $( — not inside a
# path or another word ("high", "~/.config/gh/", "git log --grep gh").
printf '%s' "$cmd" | grep -Eq '(^|[;&|(]|\$\()[[:space:]]*gh[[:space:]]' || exit 0

# shellcheck source=hooks/hook-output-lib.sh
. "$(dirname "$0")/hook-output-lib.sh"

hook_warn PreToolUse <<'EOF'
[gh-sandbox] This runs `gh` inside the sandbox. gh keeps its login in a
deny-read config file, so it fails or returns NOTHING here — and empty output
looks exactly like "no open PRs" or "no results". Re-run it with the sandbox
disabled before reading any result, and never treat an empty answer from a
sandboxed gh as a finding.
EOF
exit 0
