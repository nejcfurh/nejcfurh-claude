#!/usr/bin/env bash
# Detect the most likely base (parent) branch of the current branch,
# including stacked-PR scenarios where the true parent is another
# feature branch rather than the repo default.
#
# Method: candidates are the repo default branch plus the head branches of
# other open PRs. For each candidate, count how many commits HEAD is ahead
# of the merge-base with that candidate; the smallest count wins (closest
# ancestor). A candidate is rejected unless the merge-base lies on its
# first-parent line — otherwise the candidate merely MERGED an earlier state
# of HEAD (e.g. an integration branch) and is not a true base. A PR branch
# wins only when strictly closer than the default AND unambiguous: any tie
# (PR-vs-default or PR-vs-PR) falls back to the default, so an uncertain
# result never guesses a feature branch.
#
# Output contract: prints exactly one bare branch name (e.g. `main`) on
# stdout. Diagnostics go to stderr prefixed `warning:` — consumers read
# stdout only. No `set -e`: one broken candidate must not kill the scan.

default_base="$(gh repo view --json defaultBranchRef -q .defaultBranchRef.name 2>/dev/null)"
if [ -z "$default_base" ]; then
  default_base="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||')"
fi
default_base="${default_base:-main}"

current="$(git branch --show-current 2>/dev/null)"
if [ -z "$current" ] || [ "$current" = "$default_base" ]; then
  echo "$default_base"
  exit 0
fi

# Prints the commits-ahead count (>0) when the candidate qualifies as a base;
# prints nothing when it should be ignored.
evaluate_candidate() {
  cand="$1"

  # Resolve a usable ref for the candidate: remote-tracking first, then local.
  ref=""
  if git rev-parse --verify --quiet "origin/$cand" >/dev/null; then
    ref="origin/$cand"
  elif git rev-parse --verify --quiet "$cand" >/dev/null; then
    ref="$cand"
  else
    return 0
  fi

  base_commit="$(git merge-base HEAD "$ref" 2>/dev/null)" || return 0
  [ -n "$base_commit" ] || return 0
  count="$(git rev-list --count "$base_commit"..HEAD 2>/dev/null)" || return 0
  [ -n "$count" ] || return 0
  [ "$count" -gt 0 ] 2>/dev/null || return 0

  # First-parent ancestry filter: reject candidates whose merge-base is not on
  # their own mainline — they merged us (or an ancestor), we didn't fork them.
  git rev-list --first-parent "$ref" 2>/dev/null | grep -qx "$base_commit" || return 0

  echo "$count"
}

default_count="$(evaluate_candidate "$default_base")"

best_branch=""
best_count=""
best_tie=0

if command -v gh >/dev/null 2>&1; then
  # --limit 200: the gh default of 30 can drop the true parent from the set.
  pr_heads="$(gh pr list --state open --limit 200 --json headRefName -q '.[].headRefName' 2>/dev/null)"
  while IFS= read -r cand; do
    [ -n "$cand" ] || continue
    [ "$cand" = "$current" ] && continue
    [ "$cand" = "$default_base" ] && continue

    count="$(evaluate_candidate "$cand")"
    [ -n "$count" ] || continue

    if [ -z "$best_count" ] || [ "$count" -lt "$best_count" ]; then
      best_count="$count"
      best_branch="$cand"
      best_tie=0
    elif [ "$count" -eq "$best_count" ]; then
      best_tie=1
    fi
  done <<EOF
$pr_heads
EOF
fi

answer="$default_base"
if [ -n "$best_count" ] && [ -n "$default_count" ] \
   && [ "$best_tie" -eq 0 ] && [ "$best_count" -lt "$default_count" ]; then
  answer="$best_branch"
fi

if [ "$answer" != "$default_base" ]; then
  echo "warning: detected stacked base '$answer' (closer ancestor than '$default_base')" >&2
fi

echo "$answer"
