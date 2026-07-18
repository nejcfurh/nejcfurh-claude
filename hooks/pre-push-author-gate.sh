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

# Deletion-only and tag-only pushes carry no outgoing commits — exempt. The
# old-style delete refspec (`git push origin :dead`) counts too, but only
# when EVERY refspec is a deletion — a mixed push still publishes commits.
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
