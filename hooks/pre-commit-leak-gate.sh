#!/usr/bin/env bash
# PreToolUse (Bash, git commit): stop engagement-identifying text entering the
# history of a repo that is meant to stay generic. Scans the staged content and the
# commit message.
#
# Why this exists separately from the outbound gate: that one scans what a gh
# command publishes, which is the PR body and title. An identifier reaching a shared
# repo through a *file* — a test fixture, a code comment, a doc example — never
# passes through it. That is not hypothetical: the session that built the outbound
# gate put a live ticket identifier into one of its own test fixtures, and only a
# hand-run grep caught it before the push.
#
# Scoped by the same committed .leak-guard marker, so a client's own repo is
# untouched. Matched text is never echoed. Bypass: SKIP_LEAK_GATE.

set -u

[ -n "${SKIP_LEAK_GATE:-}" ] && exit 0
command -v jq >/dev/null 2>&1 || exit 0

payload=$(cat 2>/dev/null) || exit 0
[ -n "$payload" ] || exit 0

cmd=$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null) || exit 0
[ -n "$cmd" ] || exit 0

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=hooks/git-cmd-lib.sh
. "$HOOK_DIR/git-cmd-lib.sh"
# shellcheck source=hooks/leak-patterns-lib.sh
. "$HOOK_DIR/leak-patterns-lib.sh"

git_cmd_scan commit "$cmd"
[ "$GIT_CMD_N" -gt 0 ] || exit 0

repo=$(git_cmd_repo "${GIT_CMD_CPATH[0]}") || exit 0
root=$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null) || exit 0
leak_guard_repo "$root" || exit 0

# The staged tree is what the commit publishes. The message travels with it and is
# the place the previous retro found leaks most often, so both are scanned.
pathspec=(":/")
while IFS= read -r glob; do
  [ -n "$glob" ] && pathspec+=(":(exclude,glob)$glob")
done < <(leak_allow_globs "$root")

# Added lines only. A full diff carries deletions too, so scanning it blocks the
# commit that REMOVES an identifier — punishing the cleanup and leaving the only
# way forward as the bypass. `+++` is a file header, not content.
staged=$(git -C "$repo" diff --cached -- "${pathspec[@]}" 2>/dev/null |
  grep '^+' | grep -v '^+++')

# The message is scanned whether or not any path is exempt — but not the paths in
# the command. A command run inside a project necessarily names that project in its
# own `cd` or `git -C` argument, so scanning them verbatim blocks every commit in
# the guarded repo. Tokens containing a slash are paths, not prose.
cmd_prose=$(printf '%s' "$cmd" | tr ' ' '\n' | grep -v '/' | tr '\n' ' ')
hits=$(leak_scan "$staged
$cmd_prose")

[ -n "$hits" ] || exit 0

"$HOOK_DIR/record-gate-block.sh" "pre-commit-leak-gate" "$payload" 2>/dev/null || true
{
  echo "Blocked: this repo carries .leak-guard, and the commit would publish text matching:$hits"
  echo ""
  leak_block_explainer
  echo ""
  echo "Bypass (human-only): '!'-prefix the command, or export SKIP_LEAK_GATE=1 in your shell."
} >&2
exit 2
