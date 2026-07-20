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

# Join backslash-continued lines: a flag on a continuation line is still part
# of this push. Real newlines keep separating commands (cut below).
cmd=$(printf '%s\n' "$cmd" | awk '{ if (sub(/\\$/, "")) printf "%s ", $0; else print }')

# Quoted spans are data, not arguments: a commit message mentioning `git push`
# must not put this command through the push gates. Scan a copy with quoted
# content emptied — awk reads the whole input as one record so quotes spanning
# lines strip too (\047 = single quote).
scan=$(printf '%s' "$cmd" | awk 'BEGIN{RS="\001"} {gsub("\"[^\"]*\"","\"\""); gsub("\047[^\047]*\047","\047\047"); printf "%s", $0}')

# Match `git push …` and `git -C <path> push …`.
git_push_re="git[[:space:]]+(-C[[:space:]]+(\"[^\"]*\"|'[^']*'|[^[:space:]]+)[[:space:]]+)?push"
printf '%s\n' "$scan" | grep -Eq "${git_push_re}([[:space:]]|\$)" || exit 0

# Deletion-only and tag-only pushes publish no new code — exempt. The
# old-style delete refspec (`git push origin :dead`) counts too, but only
# when EVERY refspec is a deletion — a mixed push still publishes code.
# Arguments are anchored on the `git … push` match itself — NOT on the word
# "push" anywhere, which latches onto data like pre-push-*.sh filenames.
rest=$(printf '%s\n' "$scan" | sed -nE "s/.*${git_push_re}([[:space:]]|\$)//p" | head -1 | sed 's/[;&|].*//')
seen_remote=0
colon_deletes=0
other_refspecs=0
for tok in $rest; do
  case "$tok" in
    --delete|-d|--tags|--follow-tags) exit 0 ;;
    -*) : ;;
    :*) colon_deletes=1 ;;
    *) if [ "$seen_remote" -eq 0 ]; then seen_remote=1; else other_refspecs=1; fi ;;
  esac
done
[ "$colon_deletes" -eq 1 ] && [ "$other_refspecs" -eq 0 ] && exit 0

# Resolve the repo the push actually targets (same approach as the other
# push gates): `git -C <path>` or a leading `cd <path> &&` wins over the cwd.
target=""
target=$(printf '%s\n' "$cmd" | sed -n 's/.*git -C[[:space:]]\{1,\}"\([^"]*\)".*/\1/p' | head -1)
[ -n "$target" ] || target=$(printf '%s\n' "$cmd" | sed -n "s/.*git -C[[:space:]]\{1,\}'\([^']*\)'.*/\1/p" | head -1)
[ -n "$target" ] || target=$(printf '%s\n' "$cmd" | sed -n 's/.*git -C[[:space:]]\{1,\}\([^"'"'"'[:space:]][^[:space:]]*\).*/\1/p' | head -1)
[ -n "$target" ] || target=$(printf '%s\n' "$cmd" | sed -n '1s/^cd[[:space:]]\{1,\}"\([^"]*\)"[[:space:]]*&&.*/\1/p')
[ -n "$target" ] || target=$(printf '%s\n' "$cmd" | sed -n "1s/^cd[[:space:]]\{1,\}'\([^']*\)'[[:space:]]*&&.*/\1/p")
[ -n "$target" ] || target=$(printf '%s\n' "$cmd" | sed -n '1s/^cd[[:space:]]\{1,\}\([^[:space:]]*\)[[:space:]]*&&.*/\1/p')
case "$target" in *'$'*) target="" ;; esac

repo=""
for cand in "$target" "$PWD" "${CLAUDE_PROJECT_DIR:-}"; do
  [ -n "$cand" ] || continue
  [ -d "$cand" ] || continue
  if git -C "$cand" rev-parse --show-toplevel >/dev/null 2>&1; then
    repo="$cand"
    break
  fi
done
[ -n "$repo" ] || exit 0

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
