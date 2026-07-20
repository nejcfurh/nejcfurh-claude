#!/usr/bin/env bash
# Run every test suite in this directory — concurrently — and exit non-zero
# if any suite fails. Suites are hermetic (mktemp fixtures, env-var
# overrides for any shared state), so parallelism only changes wall-clock
# (~33s serial -> ~10s). Output is buffered per suite and printed in stable
# alphabetical order, so logs read identically to the old serial runner.
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
LOG_DIR=$(mktemp -d "${TMPDIR:-/tmp}/hooktest-logs.XXXXXX") || {
  echo "FATAL: cannot create temp directories — refusing to run suites." >&2
  exit 1
}
trap 'rm -rf "$LOG_DIR"; rmdir "$SAFE_CWD" 2>/dev/null' EXIT
cd "$SAFE_CWD" || exit 1

suites=("$SCRIPT_DIR"/*.test.sh)
pids=()
names=()
for suite in "${suites[@]}"; do
  name=$(basename "$suite")
  names+=("$name")
  bash "$suite" >"$LOG_DIR/$name.out" 2>&1 &
  pids+=("$!")
done

failed=0
i=0
for pid in "${pids[@]}"; do
  if ! wait "$pid"; then
    failed=1
    : >"$LOG_DIR/${names[$i]}.failed"
  fi
  i=$((i + 1))
done

i=0
for suite in "${suites[@]}"; do
  echo "=== ${names[$i]}"
  cat "$LOG_DIR/${names[$i]}.out"
  echo ""
  i=$((i + 1))
done

if [ "$failed" -eq 0 ]; then
  echo "All suites passed."
else
  echo "Some suites FAILED:"
  for name in "${names[@]}"; do
    [ -f "$LOG_DIR/$name.failed" ] && echo "  - $name"
  done
fi
exit "$failed"
