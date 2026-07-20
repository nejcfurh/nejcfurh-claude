#!/usr/bin/env bash
# Writes the /verify-done READY marker (.git/verify-done-ok) — but only when
# the tracked tree is clean. `git push` publishes commits, not the working
# tree: checks that passed on a dirty tree ran against content a push would
# not publish, so a marker minted then would overclaim. Untracked files never
# alter the pushed commit and stay a judgment call for the verdict.
# Usage: run inside the verified checkout. Exit 0 = marker written.
set -u

git_dir=$(git rev-parse --absolute-git-dir 2>/dev/null) || {
  echo "record-verify-pass: not inside a git repository" >&2
  exit 1
}

# Both checks fail closed: an error (e.g. unborn HEAD) counts as dirty.
if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
  {
    echo "record-verify-pass: tracked changes are uncommitted — marker NOT written."
    echo "A push publishes commits only, so a pass on a dirty tree does not certify"
    echo "what a push would publish. The verdict is READY TO COMMIT, not READY:"
    echo "commit the exact tree the checks ran on, then re-run this script."
  } >&2
  exit 1
fi

head_sha=$(git rev-parse HEAD 2>/dev/null) || {
  echo "record-verify-pass: repository has no commits — nothing to certify" >&2
  exit 1
}

printf '%s\n' "$head_sha" > "$git_dir/verify-done-ok"
echo "verify-done marker recorded for commit $head_sha"
