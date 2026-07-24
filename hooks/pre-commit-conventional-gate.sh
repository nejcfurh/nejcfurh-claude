#!/usr/bin/env bash
# PreToolUse (Bash, git commit): enforce Conventional Commits on the subject line.
# Never blocks when the subject cannot be extracted (parse failures exit 0).
# Bypass: set SKIP_CONVENTIONAL_GATE to any non-empty value.

set -u

[ -n "${SKIP_CONVENTIONAL_GATE:-}" ] && exit 0
command -v jq >/dev/null 2>&1 || exit 0

payload=$(cat 2>/dev/null) || exit 0
[ -n "$payload" ] || exit 0

cmd=$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null) || exit 0

# shellcheck source=hooks/git-cmd-lib.sh
. "$(dirname "$0")/git-cmd-lib.sh"

git_cmd_scan commit "$cmd"
[ "$GIT_CMD_N" -gt 0 ] || exit 0

# Skip commit variants that reuse or intentionally omit a message.
case "$cmd" in
  *--amend*|*--fixup*|*--squash*|*--allow-empty-message*) exit 0 ;;
esac
# -c/-C reuse an existing message only AFTER the commit subcommand — before it,
# -C is `git -C <path>` (directory selection) and must not skip the gate. Read
# from the invocation's own arguments, so the flags cannot be matched inside the
# message text.
if git_commit_reuses_message "${GIT_CMD_ARGS[0]}"; then
  exit 0
fi

# --- Extract the commit subject ----------------------------------------------
subject=""
if printf '%s\n' "$cmd" | grep -q '<<'; then
  # Heredoc message: subject is the first line after the heredoc marker.
  subject=$(printf '%s\n' "$cmd" | awk 'found { print; exit } /<</ { found = 1 }')
else
  subject=$(git_commit_message "${GIT_CMD_ARGS[0]}")
fi

# Extraction failed -> never block on a parse failure.
[ -n "$subject" ] || exit 0

# Merge/revert commits produced by git itself are exempt.
case "$subject" in
  Merge*|Revert*) exit 0 ;;
esac

if printf '%s\n' "$subject" \
  | grep -Eq '^(feat|fix|refactor|perf|docs|style|test|build|ci|chore|deps|security|revert)(\([a-zA-Z0-9./_-]+\))?!?: .+'; then
  exit 0
fi

"$(dirname "$0")/record-gate-block.sh" "pre-commit-conventional-gate" "$payload" 2>/dev/null || true
{
  echo "Blocked: commit subject does not follow Conventional Commits."
  echo ""
  # A body arrives joined onto the subject by the tokenizer; show the head of it
  # rather than replaying a whole commit message back at the user.
  echo "  Subject:  $(printf '%s' "$subject" | cut -c1-100)"
  echo "  Expected: <type>(<optional-scope>): <description>"
  echo "  Types:    feat fix refactor perf docs style test build ci chore deps security revert"
  echo "  Example:  feat(auth): add passwordless login"
  echo ""
  echo "Bypass (human-only): '!'-prefix the command, or export SKIP_CONVENTIONAL_GATE=1 in your shell."
} >&2
exit 2
