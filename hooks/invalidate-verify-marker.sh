#!/usr/bin/env bash
# PostToolUse (Write|Edit): any file modification invalidates the containing
# repo's /verify-done marker — checks that passed before an edit say nothing
# about the tree after it. Silent; never fails.

set -u

command -v jq >/dev/null 2>&1 || exit 0

payload=$(cat 2>/dev/null) || exit 0
[ -n "$payload" ] || exit 0

fp=$(printf '%s' "$payload" | jq -r '.tool_input.file_path // empty' 2>/dev/null) || exit 0
[ -n "$fp" ] || exit 0

d=$(dirname "$fp")
[ -d "$d" ] || exit 0

git_dir=$(git -C "$d" rev-parse --absolute-git-dir 2>/dev/null) || exit 0
[ -n "$git_dir" ] || exit 0

rm -f "$git_dir/verify-done-ok" 2>/dev/null
exit 0
