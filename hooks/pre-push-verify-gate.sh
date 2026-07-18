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

# Match `git push …` and `git -C <path> push …`.
printf '%s\n' "$cmd" | grep -Eq "git[[:space:]]+(-C[[:space:]]+(\"[^\"]*\"|'[^']*'|[^[:space:]]+)[[:space:]]+)?push([[:space:]]|\$)" || exit 0

# Deletion-only and tag-only pushes publish no new code — exempt.
rest="${cmd#*push}"
rest=$(printf '%s\n' "$rest" | head -1 | sed 's/[;&|].*//')
for tok in $rest; do
  case "$tok" in
    --delete|-d|--tags|--follow-tags) exit 0 ;;
  esac
done

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
if [ -f "$marker" ]; then
  if [ -n "$(find "$marker" -mmin -"$ttl" 2>/dev/null)" ]; then
    exit 0
  fi
  reason="is older than $ttl minutes"
else
  reason="was not found"
fi

"$(dirname "$0")/record-gate-block.sh" "pre-push-verify-gate" "$payload" 2>/dev/null || true
{
  echo "Blocked: no fresh /verify-done pass for this repo (marker $reason)."
  echo "Run /verify-done — a READY verdict records the pass — then push."
  echo "Note: editing any file after a pass invalidates it; re-run /verify-done."
  echo "Bypass (human-only): '!'-prefix the command, or export SKIP_VERIFY_GATE=1 in your shell."
} >&2
exit 2
