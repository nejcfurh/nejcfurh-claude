#!/usr/bin/env bash
# Prints one hash covering everything that determines a project's check plan:
# CI workflow files, package manifests, and lockfiles (working-tree content).
# /verify-done caches its discovered plan in .git/verify-done-plan keyed by
# this value — a matching key means the cached commands still apply; anything
# else means rediscover. git hash-object is used throughout so macOS and
# Linux produce identical fingerprints.
set -u

repo=$(git rev-parse --show-toplevel 2>/dev/null) || {
  echo "verify-plan-fingerprint: not inside a git repository" >&2
  exit 1
}
cd "$repo" || exit 1

{
  git ls-files -- \
    '.github/workflows/*' \
    'package.json' '*/package.json' \
    'package-lock.json' 'yarn.lock' 'pnpm-lock.yaml' 'bun.lock' 'bun.lockb' \
    2>/dev/null
  # Plan inputs created this session but not yet tracked still shape the plan.
  for f in .github/workflows/* package.json package-lock.json yarn.lock \
    pnpm-lock.yaml bun.lock bun.lockb; do
    [ -f "$f" ] && printf '%s\n' "$f"
  done
} | sort -u | while IFS= read -r f; do
  [ -f "$f" ] || continue
  printf '%s %s\n' "$f" "$(git hash-object -- "$f" 2>/dev/null)"
done | git hash-object --stdin
