#!/usr/bin/env bash
# Detect the most likely base (parent) branch of the current branch,
# including stacked-PR scenarios where the true parent is another
# feature branch rather than the repo default.
#
# Method: candidates are the repo default branch plus the head branches of
# other open PRs. For each candidate, count how many commits HEAD is ahead
# of the merge-base with that candidate; the smallest count wins (closest
# ancestor). Ties go to the default branch.
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

# Candidate list: default branch first, then open PR head branches.
candidates="$default_base"
if command -v gh >/dev/null 2>&1; then
  pr_heads="$(gh pr list --state open --json headRefName -q '.[].headRefName' 2>/dev/null)"
  candidates="$candidates
$pr_heads"
fi

best_branch=""
best_count=""

while IFS= read -r cand; do
  [ -n "$cand" ] || continue
  [ "$cand" = "$current" ] && continue

  # Resolve a usable ref for the candidate: remote-tracking first, then local.
  ref=""
  if git rev-parse --verify --quiet "origin/$cand" >/dev/null; then
    ref="origin/$cand"
  elif git rev-parse --verify --quiet "$cand" >/dev/null; then
    ref="$cand"
  else
    continue
  fi

  base_commit="$(git merge-base HEAD "$ref" 2>/dev/null)" || continue
  [ -n "$base_commit" ] || continue
  count="$(git rev-list --count "$base_commit"..HEAD 2>/dev/null)" || continue
  [ -n "$count" ] || continue

  # Strictly smaller wins; ties keep the earlier candidate (default is first).
  if [ -z "$best_count" ] || [ "$count" -lt "$best_count" ]; then
    best_count="$count"
    best_branch="$cand"
  fi
done <<EOF
$candidates
EOF

best_branch="${best_branch:-$default_base}"

if [ "$best_branch" != "$default_base" ]; then
  echo "warning: detected stacked base '$best_branch' (closer ancestor than '$default_base')" >&2
fi

echo "$best_branch"
