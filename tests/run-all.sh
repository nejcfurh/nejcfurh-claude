#!/usr/bin/env bash
# Run every test suite in this directory. Exit non-zero if any suite fails.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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
