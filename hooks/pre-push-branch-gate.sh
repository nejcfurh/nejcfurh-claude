#!/usr/bin/env bash
# PreToolUse (Bash, git push): block pushes that target the repo's DEFAULT
# branch, whatever it is named. Permission-rule globs can only string-match
# the literal word "main"; this gate resolves the actual push target — bare
# `git push` on the default branch, `HEAD`, refspecs, --all/--delete — and
# compares it against the branch origin/HEAD points at.
# Never blocks when the default branch cannot be determined.
# Bypass: set SKIP_PUSH_BRANCH_GATE to any non-empty value.

set -u

[ -n "${SKIP_PUSH_BRANCH_GATE:-}" ] && exit 0
command -v jq >/dev/null 2>&1 || exit 0

payload=$(cat 2>/dev/null) || exit 0
[ -n "$payload" ] || exit 0

cmd=$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null) || exit 0

# Match `git push …` and `git -C <path> push …`.
printf '%s\n' "$cmd" | grep -Eq "git[[:space:]]+(-C[[:space:]]+(\"[^\"]*\"|'[^']*'|[^[:space:]]+)[[:space:]]+)?push([[:space:]]|\$)" || exit 0

# Resolve the repo the push actually targets (same approach as the commit
# branch gate): `git -C <path>` or a leading `cd <path> &&` wins over the cwd.
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

# The repo's default branch: origin/HEAD first, then well-known names.
default=$(git -C "$repo" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||')
if [ -z "$default" ]; then
  if git -C "$repo" rev-parse --verify --quiet origin/main >/dev/null; then
    default="main"
  elif git -C "$repo" rev-parse --verify --quiet origin/master >/dev/null; then
    default="master"
  fi
fi
[ -n "$default" ] || exit 0

# Arguments of the push invocation: everything after the first `push`, cut at
# the next command separator. Pragmatic — quoted separators inside messages
# are not push arguments anyway, and a misparse degrades to the conservative
# current-branch check below.
rest="${cmd#*push}"
rest=$(printf '%s\n' "$rest" | head -1 | sed 's/[;&|].*//')

remote=""
refspecs=""
push_everything=0
tags_only_hint=0
skip_next=0
for tok in $rest; do
  if [ "$skip_next" = 1 ]; then skip_next=0; continue; fi
  case "$tok" in
    --all|--mirror|--branches) push_everything=1 ;;
    --tags|--follow-tags) tags_only_hint=1 ;;
    -o|--push-option|--repo|--receive-pack|--exec) skip_next=1 ;;
    --*=*) : ;;
    -*) : ;;
    *)
      if [ -z "$remote" ]; then remote="$tok"; else refspecs="$refspecs $tok"; fi
      ;;
  esac
done

# Collect the branches this push would update on the remote.
targets=""
if [ "$push_everything" = 1 ]; then
  targets="$default"
elif [ -n "$refspecs" ]; then
  for rs in $refspecs; do
    rs="${rs#+}"
    dst="${rs#*:}"                       # dst of src:dst; the whole spec if no colon
    [ -n "$dst" ] || continue            # "branch:" — nothing to update
    case "$dst" in
      refs/heads/*) dst="${dst#refs/heads/}" ;;
      refs/*) continue ;;                # tags/notes/etc — not a branch push
    esac
    if [ "$dst" = "HEAD" ]; then
      dst=$(git -C "$repo" branch --show-current 2>/dev/null)
    fi
    targets="$targets $dst"
  done
elif [ "$tags_only_hint" = 0 ]; then
  # Bare `git push` (or `git push <remote>`): pushes the current branch.
  targets=$(git -C "$repo" branch --show-current 2>/dev/null)
fi

for t in $targets; do
  [ -n "$t" ] || continue
  if [ "$t" = "$default" ]; then
    {
      echo "Blocked: this push targets '$default' — the repo's default branch."
      echo "Push a feature branch and open a PR instead."
      echo "Bypass (human-only): '!'-prefix the command, or export SKIP_PUSH_BRANCH_GATE=1 in your shell."
    } >&2
    exit 2
  fi
done

exit 0
