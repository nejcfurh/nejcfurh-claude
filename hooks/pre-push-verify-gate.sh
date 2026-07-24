#!/usr/bin/env bash
# PreToolUse (Bash, git push): require a fresh /verify-done pass before any
# push. A READY verdict from /verify-done records a marker in
# .git/verify-done-ok; any Write/Edit afterwards deletes it
# (invalidate-verify-marker.sh), and a TTL backstop expires it. Deletion-only
# and tag-only pushes are exempt. Never blocks when repo state cannot be
# determined.
# Bypass: set SKIP_VERIFY_GATE to any non-empty value.

set -u

[ -n "${SKIP_VERIFY_GATE:-}" ] && exit 0
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

# Deletion-only and tag-only pushes publish no new code — exempt. The exemption
# must hold for EVERY push in the command: one exempt invocation used to exit 0
# for the whole line, so `git push --tags && git push origin main` skipped this
# gate. `--follow-tags` is not exempt — it publishes the current branch too.
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

git_dir=$(git -C "$repo" rev-parse --absolute-git-dir 2>/dev/null) || exit 0
[ -n "$git_dir" ] || exit 0
marker="$git_dir/verify-done-ok"

ttl="${VERIFY_DONE_TTL_MINUTES:-120}"
if [ ! -f "$marker" ]; then
  reason="was not found"
elif [ -z "$(find "$marker" -mmin -"$ttl" 2>/dev/null)" ]; then
  reason="is older than $ttl minutes"
else
  # Bind the pass to the exact commit: /verify-done writes the verified HEAD
  # as the marker's first line, so a marker recorded for an earlier commit
  # cannot certify a push of a later one (rebase/amend/extra commit).
  marker_head=$(head -n1 "$marker" 2>/dev/null | tr -d '[:space:]')
  cur_head=$(git -C "$repo" rev-parse HEAD 2>/dev/null)
  if [ -n "$marker_head" ] && [ -n "$cur_head" ] && [ "$marker_head" = "$cur_head" ]; then
    exit 0
  fi
  reason="does not match the current commit — HEAD moved since the pass"
fi

"$(dirname "$0")/record-gate-block.sh" "pre-push-verify-gate" "$payload" 2>/dev/null || true
{
  echo "Blocked: no fresh /verify-done pass for this repo (marker $reason)."
  echo "Run /verify-done — a READY verdict records the pass — then push."
  echo "Note: editing any file after a pass invalidates it; re-run /verify-done."
  echo "Bypass (human-only): '!'-prefix the command, or export SKIP_VERIFY_GATE=1 in your shell."
} >&2
exit 2
