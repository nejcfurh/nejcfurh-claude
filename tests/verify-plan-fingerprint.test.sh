#!/usr/bin/env bash
# Regression tests for scripts/verify-plan-fingerprint.sh.
#
# The fingerprint must change exactly when a check-plan input changes (CI
# workflows, package manifests, lockfiles — tracked or not) and stay stable
# for everything else, so /verify-done's plan cache never serves a stale plan
# and never rediscovers needlessly. Run: bash verify-plan-fingerprint.test.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# A failed mktemp must never leak this suite's git commands into the real repo.
cd "$(mktemp -d "${TMPDIR:-/tmp}/hooktest-cwd.XXXXXX")" || exit 1
SUT="$SCRIPT_DIR/../scripts/verify-plan-fingerprint.sh"

pass=0
fail=0

export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@test
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@test

check() { # check <name> <command…> — passes when the command exits 0
  local name="$1"
  shift
  if "$@"; then
    echo "PASS: $name"
    pass=$((pass + 1))
  else
    echo "FAIL: $name"
    fail=$((fail + 1))
  fi
}

fp() { (cd "$1" && bash "$SUT" 2>/dev/null); }

repo=$(mktemp -d "${TMPDIR:-/tmp}/hooktest.XXXXXX")
other=$(mktemp -d "${TMPDIR:-/tmp}/hooktest.XXXXXX")
(cd "$repo" && git init -q -b feat/topic \
  && mkdir -p .github/workflows src \
  && printf 'name: ci\n' > .github/workflows/ci.yml \
  && printf '{"scripts":{"test":"true"}}\n' > package.json \
  && printf 'export {}\n' > src/index.ts \
  && git add -A && git commit -q -m "feat: init")

base=$(fp "$repo")

check "produces a non-empty fingerprint" [ -n "$base" ]
check "is deterministic across runs" [ "$(fp "$repo")" = "$base" ]

sub_matches() { [ "$(cd "$repo/src" && bash "$SUT" 2>/dev/null)" = "$base" ]; }
check "same result from a subdirectory" sub_matches

# Unrelated source edits must NOT invalidate the cached plan.
src_stable() {
  echo "export const x = 1" >> "$repo/src/index.ts"
  [ "$(fp "$repo")" = "$base" ]
}
check "unrelated source edit keeps fingerprint" src_stable

# Uncommitted manifest edits MUST invalidate — the plan follows the working
# tree, not the last commit.
manifest_changes() {
  printf '{"scripts":{"test":"true","lint":"true"}}\n' > "$repo/package.json"
  [ "$(fp "$repo")" != "$base" ]
}
check "uncommitted package.json edit changes fingerprint" manifest_changes
after_manifest=$(fp "$repo")

# A brand-new, untracked workflow file is a plan input too.
untracked_workflow_changes() {
  printf 'name: extra\n' > "$repo/.github/workflows/extra.yml"
  [ "$(fp "$repo")" != "$after_manifest" ]
}
check "untracked workflow file changes fingerprint" untracked_workflow_changes

# A workspace manifest below the root counts as well.
nested_manifest_changes() {
  before=$(fp "$repo")
  mkdir -p "$repo/packages/app"
  printf '{"scripts":{"test":"true"}}\n' > "$repo/packages/app/package.json"
  (cd "$repo" && git add packages && git commit -q -m "feat: workspace")
  [ "$(fp "$repo")" != "$before" ]
}
check "nested package.json changes fingerprint" nested_manifest_changes

# Lockfile churn (e.g. dependency bump) invalidates.
lockfile_changes() {
  before=$(fp "$repo")
  printf 'lockfileVersion: 9\n' > "$repo/pnpm-lock.yaml"
  [ "$(fp "$repo")" != "$before" ]
}
check "lockfile change changes fingerprint" lockfile_changes

outside_fails() { ! (cd "$other" && bash "$SUT" >/dev/null 2>&1); }
check "outside a repo exits non-zero" outside_fails

rm -rf "$repo" "$other"

echo ""
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
