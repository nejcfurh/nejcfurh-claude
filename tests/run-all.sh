#!/usr/bin/env bash
# Run every test suite in this directory. Exit non-zero if any suite fails.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Run suites from a throwaway cwd, never from inside the real repo: if a
# suite's mktemp fails and leaves a path variable empty, its `git -C ""` /
# `cd ""` commands fall through to the cwd — from here that is a non-repo
# and git errors out, instead of committing test fixtures into this repo.
SAFE_CWD=$(mktemp -d "${TMPDIR:-/tmp}/hooktest-cwd.XXXXXX") || {
  echo "FATAL: cannot create temp directories — refusing to run suites." >&2
  exit 1
}
trap 'rmdir "$SAFE_CWD" 2>/dev/null' EXIT
cd "$SAFE_CWD" || exit 1

failed=0
for suite in "$SCRIPT_DIR"/*.test.sh; do
  echo "=== $(basename "$suite")"
  bash "$suite" || failed=1
  echo ""
done

if [ "$failed" -eq 0 ]; then
  echo "All suites passed."
else
  echo "Some suites FAILED."
fi
exit "$failed"
