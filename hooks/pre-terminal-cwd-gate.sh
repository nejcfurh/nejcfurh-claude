#!/usr/bin/env bash
# PreToolUse (an app tool that types a command into a new terminal tab): refuse
# the call when the session works in a linked git worktree and the call names no
# working directory.
#
# Such a tool opens its tab in the session's starting folder, which for a
# worktree session can be the user's own main checkout. The command then runs in
# a tree the user is working in, on whatever branch they left it on, and nothing
# in the call's result says where it ran. Naming the folder costs one argument.
#
# Only the linked-worktree case is gated: in a plain checkout the starting
# folder and the session's folder are the same place.
#
# Bypass: set SKIP_TERMINAL_CWD_GATE to any non-empty value.

set -u

[ -n "${SKIP_TERMINAL_CWD_GATE:-}" ] && exit 0

payload=$(cat 2>/dev/null) || exit 0
[ -n "$payload" ] || exit 0

command -v jq >/dev/null 2>&1 || exit 0

target=$(printf '%s' "$payload" | jq -r '.tool_input.cwd // empty' 2>/dev/null) || exit 0
[ -z "$target" ] || exit 0

here=$(printf '%s' "$payload" | jq -r '.cwd // empty' 2>/dev/null) || exit 0
[ -n "$here" ] && [ -d "$here" ] || exit 0

git_dir=$(git -C "$here" rev-parse --absolute-git-dir 2>/dev/null) || exit 0
common_dir=$(cd "$(git -C "$here" rev-parse --git-common-dir 2>/dev/null)" 2>/dev/null && pwd -P) || exit 0
[ "$(cd "$git_dir" && pwd -P)" != "$common_dir" ] || exit 0

top=$(git -C "$here" rev-parse --show-toplevel 2>/dev/null) || top="$here"

"$(dirname "$0")/record-gate-block.sh" "pre-terminal-cwd-gate" "$payload" 2>/dev/null || true

reason=""
read -r -d '' reason <<MSG || true
This session works in a linked git worktree, and this terminal call names no cwd. A new tab may open in the starting folder, which can be the user's main checkout, so the command would run in their tree.

Pass cwd explicitly, for example cwd: "$top".

False positive? Set SKIP_TERMINAL_CWD_GATE=1 for the call.
MSG

jq -cn --arg r "$reason" \
  '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
exit 0
