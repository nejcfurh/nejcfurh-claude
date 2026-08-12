#!/usr/bin/env bash
# PreToolUse (Bash, git push): reject a command that records the verify-done
# marker and pushes in the same invocation.
#
# PreToolUse gates evaluate the whole command BEFORE any of it runs, so the
# marker the recorder would write does not exist yet when pre-push-verify-gate
# looks for it. The chained form therefore always fails, and it fails with the
# confusing "no fresh pass" message rather than naming the real cause. Blocking
# it here turns a mystifying rejection into an instruction.
# Bypass: set SKIP_MARKER_CHAIN_GATE to any non-empty value.

set -u

[ -n "${SKIP_MARKER_CHAIN_GATE:-}" ] && exit 0
command -v jq >/dev/null 2>&1 || exit 0

payload=$(cat 2>/dev/null) || exit 0
[ -n "$payload" ] || exit 0

cmd=$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null) || exit 0
[ -n "$cmd" ] || exit 0

# Only the recorder matters. Reading the marker (a `cat`/`test` on the path) is
# harmless in the same line; writing it is what cannot precede the gate.
case "$cmd" in
  *record-verify-pass*) ;;
  *) exit 0 ;;
esac

# shellcheck source=hooks/git-cmd-lib.sh
. "$(dirname "$0")/git-cmd-lib.sh"

git_cmd_scan push "$cmd"
[ "$GIT_CMD_N" -gt 0 ] || exit 0

# Deletion- and tag-only pushes never consult the marker, so chaining them is
# not the mistake this gate exists to catch.
i=0
publishes=0
while [ "$i" -lt "$GIT_CMD_N" ]; do
  if git_push_publishes_code "${GIT_CMD_ARGS[$i]}"; then publishes=1; break; fi
  i=$((i + 1))
done
[ "$publishes" -eq 1 ] || exit 0

"$(dirname "$0")/record-gate-block.sh" "pre-push-marker-chain-gate" "$payload" 2>/dev/null || true
{
  echo "Blocked: the verify-done marker is recorded and pushed in one command."
  echo "PreToolUse gates read the whole command before any of it runs, so the"
  echo "marker does not exist yet when the push gate checks for it — this form"
  echo "can never pass, and fails as a confusing 'no fresh pass' error."
  echo "Fix: run the recorder as its own command, then push in the next one."
  echo "Bypass (human-only): '!'-prefix the command, or export SKIP_MARKER_CHAIN_GATE=1."
} >&2
exit 2
