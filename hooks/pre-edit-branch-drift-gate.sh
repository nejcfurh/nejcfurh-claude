#!/usr/bin/env bash
# PreToolUse (Write|Edit): warn when the branch under an edit is not the branch
# this session last edited in that repository.
#
# A checkout can change branch between turns — a second session, a colleague, a
# script. Edits made afterwards land in whatever tree is now checked out, with no
# conflict and no error, so the work silently mixes into someone else's
# uncommitted changes. It surfaces at staging, by which point separating the two
# means picking your files out of a diff you did not write.
#
# The branch is recorded per (session, repository) on the first edit and compared
# on every edit after it. Only a change is worth saying anything about: the first
# edit in a repo has nothing to compare against and stays quiet.
#
# Non-blocking. A branch change is frequently deliberate — the session switched
# on purpose, or a worktree was just created — so this reports the fact and lets
# the edit through.
#
# Bypass: set SKIP_EDIT_BRANCH_DRIFT_GATE to any non-empty value.

set -u

[ -n "${SKIP_EDIT_BRANCH_DRIFT_GATE:-}" ] && exit 0

payload=$(cat 2>/dev/null) || exit 0
[ -n "$payload" ] || exit 0

command -v jq >/dev/null 2>&1 || exit 0
command -v git >/dev/null 2>&1 || exit 0

file=$(printf '%s' "$payload" | jq -r '.tool_input.file_path // empty' 2>/dev/null) || exit 0
[ -n "$file" ] || exit 0

session=$(printf '%s' "$payload" | jq -r '.session_id // empty' 2>/dev/null) || exit 0
[ -n "$session" ] || exit 0

# The directory is what git needs, and the file itself may not exist yet.
dir=$(dirname "$file")
[ -d "$dir" ] || exit 0

# Worktrees of one repository are separate trees on separate branches, so the
# key is the working tree, not the shared git dir.
toplevel=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null) || exit 0
[ -n "$toplevel" ] || exit 0

branch=$(git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null) || exit 0
[ -n "$branch" ] || exit 0

state_dir="${EDIT_BRANCH_STATE_DIR:-$HOME/.claude/state/edit-branch}"
mkdir -p "$state_dir" 2>/dev/null || exit 0

# One file per session and working tree. The path is hashed because a tree path
# contains slashes and is of unbounded length.
if command -v shasum >/dev/null 2>&1; then
  tree_key=$(printf '%s' "$toplevel" | shasum | cut -d' ' -f1)
elif command -v sha1sum >/dev/null 2>&1; then
  tree_key=$(printf '%s' "$toplevel" | sha1sum | cut -d' ' -f1)
else
  exit 0
fi

state_file="$state_dir/${session}-${tree_key}"

previous=""
[ -f "$state_file" ] && previous=$(cat "$state_file" 2>/dev/null)

printf '%s' "$branch" > "$state_file" 2>/dev/null || exit 0

# Nothing to compare on the first edit, and nothing to say when it has not moved.
[ -n "$previous" ] || exit 0
[ "$previous" = "$branch" ] && exit 0

# shellcheck source=hooks/hook-output-lib.sh
. "$(dirname "$0")/hook-output-lib.sh"

hook_warn PreToolUse <<EOF
[edit-branch-drift] This checkout was on '$previous' when this session last
edited it and is on '$branch' now: $toplevel

Something moved it — another session, another person, a script. Edits land in
whatever tree is checked out now, without conflict, so confirm the branch is the
one you mean before continuing. If the tree belongs to someone else, leave it
where it is and take your own with 'git worktree add'; if you have already
edited, isolate your paths with a scoped patch and restore only those paths.
EOF
exit 0
