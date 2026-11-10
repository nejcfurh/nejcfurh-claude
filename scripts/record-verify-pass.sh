#!/usr/bin/env bash
# Writes the /verify-done READY marker (.git/verify-done-ok) — but only when
# the tracked tree is clean. `git push` publishes commits, not the working
# tree: checks that passed on a dirty tree ran against content a push would
# not publish, so a marker minted then would overclaim. Untracked files never
# alter the pushed commit and stay a judgment call for the verdict.
# The marker also records how much of the test suite the pass ran
# (line 2: mode=scoped|full). Gates read line 1 only; the mode is for the
# reader, and it must be stated — an unlabelled marker would let a scoped pass
# read as a full one.
# Usage: record-verify-pass.sh --mode scoped|full — run inside the verified
# checkout. Exit 0 = marker written.
set -u

mode=""
while [ $# -gt 0 ]; do
  case "$1" in
    --mode) mode="${2:-}"; shift 2 ;;
    --mode=*) mode="${1#--mode=}"; shift ;;
    *) echo "record-verify-pass: unknown argument: $1" >&2; exit 2 ;;
  esac
done
case "$mode" in
  scoped | full) ;;
  *)
    echo "record-verify-pass: --mode scoped|full is required (the mode verify-run.sh reported)" >&2
    exit 2 ;;
esac

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

printf '%s\nmode=%s\n' "$head_sha" "$mode" > "$git_dir/verify-done-ok"
echo "verify-done marker recorded for commit $head_sha (mode=$mode)"
