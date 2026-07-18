#!/usr/bin/env bash
# PreToolUse (Bash, git push): block pushes whose outgoing commits carry an
# author other than the configured user — the signature of fixture commits,
# tooling artifacts, or another branch's history riding along unnoticed.
# Outgoing = upstream..HEAD, falling back to origin/<default>..HEAD for
# branches with no upstream yet. Never blocks when the range, the remote, or
# the user email cannot be determined.
# Bypass: set SKIP_PUSH_AUTHOR_GATE to any non-empty value.

set -u

[ -n "${SKIP_PUSH_AUTHOR_GATE:-}" ] && exit 0
command -v jq >/dev/null 2>&1 || exit 0

payload=$(cat 2>/dev/null) || exit 0
[ -n "$payload" ] || exit 0

cmd=$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null) || exit 0

# Match `git push …` and `git -C <path> push …`.
printf '%s\n' "$cmd" | grep -Eq "git[[:space:]]+(-C[[:space:]]+(\"[^\"]*\"|'[^']*'|[^[:space:]]+)[[:space:]]+)?push([[:space:]]|\$)" || exit 0

# Deletion-only and tag-only pushes carry no outgoing commits — exempt.
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

me=$(git -C "$repo" config user.email 2>/dev/null)
[ -n "$me" ] || exit 0

# The range this push would publish: upstream first, default branch fallback.
range=""
if git -C "$repo" rev-parse --verify --quiet '@{u}' >/dev/null 2>&1; then
  range='@{u}..HEAD'
else
  default=$(git -C "$repo" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||')
  if [ -z "$default" ]; then
    if git -C "$repo" rev-parse --verify --quiet origin/main >/dev/null; then
      default="main"
    elif git -C "$repo" rev-parse --verify --quiet origin/master >/dev/null; then
      default="master"
    fi
  fi
  [ -n "$default" ] || exit 0
  range="origin/$default..HEAD"
fi

foreign=$(git -C "$repo" log --format='%h %ae  %s' "$range" 2>/dev/null \
  | awk -v me="$me" 'BEGIN { IGNORECASE = 0 } { if (tolower($2) != tolower(me)) print }')
[ -n "$foreign" ] || exit 0

count=$(printf '%s\n' "$foreign" | wc -l | tr -d '[:space:]')
"$(dirname "$0")/record-gate-block.sh" "pre-push-author-gate" "$payload" 2>/dev/null || true
{
  echo "Blocked: $count outgoing commit(s) ($range) are not authored by $me."
  echo "Fixture commits, tooling artifacts, or another branch's history may be riding along:"
  echo ""
  printf '%s\n' "$foreign" | head -10
  echo ""
  echo "Review the outgoing range and rebase the strays away before pushing."
  echo "Bypass (human-only): '!'-prefix the command, or export SKIP_PUSH_AUTHOR_GATE=1 in your shell."
} >&2
exit 2
