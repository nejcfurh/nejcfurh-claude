#!/usr/bin/env bash
# PreToolUse (Bash, git push): block pushes whose outgoing commits carry an
# author other than the configured user — the signature of fixture commits,
# tooling artifacts, or another branch's history riding along unnoticed.
# Outgoing = HEAD --not --remotes: anything already fetched from a remote
# (a colleague's branch you stacked on) is fine; commits that exist nowhere
# but this clone must be the user's own. Never blocks when remote state or
# the user email cannot be determined.
# Bypass: set SKIP_PUSH_AUTHOR_GATE to any non-empty value.

set -u

[ -n "${SKIP_PUSH_AUTHOR_GATE:-}" ] && exit 0
command -v jq >/dev/null 2>&1 || exit 0

payload=$(cat 2>/dev/null) || exit 0
[ -n "$payload" ] || exit 0

cmd=$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null) || exit 0

# shellcheck source=hooks/git-cmd-lib.sh
. "$(dirname "$0")/git-cmd-lib.sh"

# Every `git … push` in the command, whatever git-level options precede it. The
# tokenizer handles backslash continuations and quoted spans itself, so a commit
# message mentioning `git push` stays data and does not reach this gate.
git_cmd_scan push "$cmd"
[ "$GIT_CMD_N" -gt 0 ] || exit 0

# Deletion-only and tag-only pushes carry no outgoing commits — exempt. The
# exemption must hold for EVERY push in the command: one exempt invocation used
# to exit 0 for the whole line, so `git push --tags && git push origin main`
# skipped this gate. `--follow-tags` is not exempt — it publishes commits too.
pub_idx=-1
i=0
while [ "$i" -lt "$GIT_CMD_N" ]; do
  if git_push_publishes_code "${GIT_CMD_ARGS[$i]}"; then pub_idx="$i"; break; fi
  i=$((i + 1))
done
[ "$pub_idx" -ge 0 ] || exit 0

# Resolve the repo that push targets: `git -C <path>` or a leading
# `cd <path> &&` wins over the cwd.
repo=$(git_cmd_repo "${GIT_CMD_CPATH[$pub_idx]}") || exit 0

me=$(git -C "$repo" config user.email 2>/dev/null)
[ -n "$me" ] || exit 0

# Outgoing = commits not reachable from ANY remote ref. Work fetched from a
# colleague lives under refs/remotes/* and is excluded, so stacking on their
# branch never blocks — only commits that exist nowhere but this clone must
# be the user's own. No remote refs at all -> undeterminable, never block.
git -C "$repo" for-each-ref --count=1 refs/remotes | grep -q . || exit 0

foreign=$(git -C "$repo" log --format='%h %ae  %s' HEAD --not --remotes 2>/dev/null \
  | awk -v me="$me" 'BEGIN { IGNORECASE = 0 } { if (tolower($2) != tolower(me)) print }')
[ -n "$foreign" ] || exit 0

count=$(printf '%s\n' "$foreign" | wc -l | tr -d '[:space:]')
"$(dirname "$0")/record-gate-block.sh" "pre-push-author-gate" "$payload" 2>/dev/null || true
{
  echo "Blocked: $count outgoing commit(s) (HEAD --not --remotes) are not authored by $me."
  echo "Fixture commits, tooling artifacts, or another branch's history may be riding along:"
  echo ""
  printf '%s\n' "$foreign" | head -10
  echo ""
  echo "Review the outgoing range and rebase the strays away before pushing."
  echo "Bypass (human-only): '!'-prefix the command, or export SKIP_PUSH_AUTHOR_GATE=1 in your shell."
} >&2
exit 2
