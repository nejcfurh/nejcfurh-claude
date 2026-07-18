#!/usr/bin/env bash
# PreToolUse (Bash, git commit): block commits made directly on main/master.
# Bypass: set SKIP_COMMIT_BRANCH_GATE to any non-empty value.

set -u

[ -n "${SKIP_COMMIT_BRANCH_GATE:-}" ] && exit 0
command -v jq >/dev/null 2>&1 || exit 0

payload=$(cat 2>/dev/null) || exit 0
[ -n "$payload" ] || exit 0

cmd=$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null) || exit 0
# Match both `git commit …` and `git -C <path> commit …` — the -C form has no
# literal "git commit" substring and would otherwise bypass the gate.
if ! printf '%s\n' "$cmd" | grep -Eq "git[[:space:]]+-C[[:space:]]+(\"[^\"]*\"|'[^']*'|[^[:space:]]+)[[:space:]]+commit([[:space:]]|\$)"; then
  case "$cmd" in
    *"git commit"*) : ;;
    *) exit 0 ;;
  esac
fi

# Resolve the repo the commit actually TARGETS, not just the session cwd —
# `git -C <path> commit` and `cd <path> && git commit` operate on a different
# repo, and gating on the cwd's branch false-blocks legitimate cross-repo work.
target=""
# git -C with a double-quoted, single-quoted, or bare path.
target=$(printf '%s\n' "$cmd" | sed -n 's/.*git -C[[:space:]]\{1,\}"\([^"]*\)".*/\1/p' | head -1)
[ -n "$target" ] || target=$(printf '%s\n' "$cmd" | sed -n "s/.*git -C[[:space:]]\{1,\}'\([^']*\)'.*/\1/p" | head -1)
[ -n "$target" ] || target=$(printf '%s\n' "$cmd" | sed -n 's/.*git -C[[:space:]]\{1,\}\([^"'"'"'[:space:]][^[:space:]]*\).*/\1/p' | head -1)
# Leading `cd <path> &&` (same quoting variants).
[ -n "$target" ] || target=$(printf '%s\n' "$cmd" | sed -n '1s/^cd[[:space:]]\{1,\}"\([^"]*\)"[[:space:]]*&&.*/\1/p')
[ -n "$target" ] || target=$(printf '%s\n' "$cmd" | sed -n "1s/^cd[[:space:]]\{1,\}'\([^']*\)'[[:space:]]*&&.*/\1/p")
[ -n "$target" ] || target=$(printf '%s\n' "$cmd" | sed -n '1s/^cd[[:space:]]\{1,\}\([^[:space:]]*\)[[:space:]]*&&.*/\1/p')
# Unexpanded variables in the extracted path can't be resolved here — ignore.
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

branch=$(git -C "$repo" branch --show-current 2>/dev/null)

# The hook runs BEFORE the command: a compound like `git checkout -b x && git
# commit …` will not be on branch x yet. Predict the branch at commit time by
# taking the LAST checkout/switch in the command portion before the commit.
pre_commit_part="${cmd%%commit*}"
switched=$(printf '%s\n' "$pre_commit_part" \
  | grep -oE "git[[:space:]]+(-C[[:space:]]+[^[:space:]]+[[:space:]]+)?(checkout[[:space:]]+-b|switch[[:space:]]+-c|checkout|switch)[[:space:]]+[^[:space:]&;|\"']+" \
  | tail -1 | awk '{print $NF}')
case "$switched" in
  -*|.|"") : ;;                      # flags, `checkout .`, nothing found — keep cwd branch
  *) branch="$switched" ;;
esac

case "$branch" in
  main|master)
    {
      echo "Blocked: commits directly to '$branch' are not allowed."
      echo "Create a feature branch first: git checkout -b <type>/<topic>"
      echo "Bypass (human-only): '!'-prefix the command, or export SKIP_COMMIT_BRANCH_GATE=1 in your shell."
    } >&2
    exit 2
    ;;
esac

exit 0
