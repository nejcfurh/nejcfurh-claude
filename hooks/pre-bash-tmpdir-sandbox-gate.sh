#!/usr/bin/env bash
# PreToolUse (Bash): warn when a command that runs OUTSIDE the sandbox names
# $TMPDIR, because the sandboxed and unsandboxed shells resolve it to two
# different directories.
#
# The failure is quiet and costs a round trip every time: a log written to
# "$TMPDIR/x.log" by an unsandboxed command is simply missing for the next,
# sandboxed `sed`/`cat`, and the error names a plausible path, so it reads as a
# vanished file rather than as two locations. Both commands look identical in
# the transcript, which is why the rule alone did not stop it recurring.
#
# Deliberately one-sided. Sandboxed commands are told to use $TMPDIR and do so
# constantly; warning on those would be noise. Unsandboxed commands are the
# unusual side of the mismatch, so that is the only side this speaks on.
#
# Non-blocking by design: a file created and consumed inside one unsandboxed
# command is fine. The fix, when the file must outlive the command, is an
# absolute path you chose, such as the session scratchpad.
#
# Bypass: set SKIP_BASH_TMPDIR_SANDBOX_GATE to any non-empty value.

set -u

[ -n "${SKIP_BASH_TMPDIR_SANDBOX_GATE:-}" ] && exit 0

payload=$(cat 2>/dev/null) || exit 0
[ -n "$payload" ] || exit 0

# Runs on EVERY Bash call: bail on a builtin match before spending a jq.
case "$payload" in
  *TMPDIR*) : ;;
  *) exit 0 ;;
esac

command -v jq >/dev/null 2>&1 || exit 0

unsandboxed=$(printf '%s' "$payload" | jq -r '.tool_input.dangerouslyDisableSandbox // false' 2>/dev/null) || exit 0
[ "$unsandboxed" = "true" ] || exit 0

cmd=$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null) || exit 0
[ -n "$cmd" ] || exit 0

printf '%s' "$cmd" | grep -Eq '\$\{?TMPDIR' || exit 0

# shellcheck source=hooks/hook-output-lib.sh
. "$(dirname "$0")/hook-output-lib.sh"

hook_warn PreToolUse <<'EOF'
[tmpdir-sandbox] This command runs outside the sandbox and names $TMPDIR.
Sandboxed and unsandboxed shells resolve $TMPDIR to DIFFERENT directories, so a
file written here is missing for a later sandboxed command, and one written by a
sandboxed command is missing here. If the file must outlive this command, use an
absolute path you chose (the session scratchpad), not $TMPDIR.
EOF
exit 0
