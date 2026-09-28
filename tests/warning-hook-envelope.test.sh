#!/usr/bin/env bash
# A non-blocking PreToolUse warning hook must emit its text through
# hook_warn (hooks/hook-output-lib.sh). Plain stdout from a hook that exits 0
# lands in the transcript only, so the model the warning is written for never
# sees it, and the hook looks healthy in every direct test of its output.
#
# Static check over hooks/pre-*.sh: a hook that prints (a line starting with
# cat <<, echo or printf) must either source hook-output-lib.sh or be a
# blocking gate (exit 2, a permissionDecision, or its own hookSpecificOutput).
#
# HOOKS_DIR overrides the directory, so the check can be run against a fixture.
# Run: bash warning-hook-envelope.test.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS_DIR=${HOOKS_DIR:-"$SCRIPT_DIR/../hooks"}

pass=0
fail=0

prints_text() {
  grep -qE '^[[:space:]]*(cat <<|echo |printf )' "$1"
}

reaches_model() {
  grep -qE 'hook-output-lib\.sh|hookSpecificOutput|permissionDecision|exit 2' "$1"
}

for hook in "$HOOKS_DIR"/pre-*.sh; do
  [ -f "$hook" ] || continue
  name=$(basename "$hook")
  if prints_text "$hook" && ! reaches_model "$hook"; then
    echo "FAIL: $name prints plain text that never reaches the model; route it through hook_warn"
    fail=$((fail + 1))
  else
    pass=$((pass + 1))
  fi
done

if [ "$pass" -eq 0 ] && [ "$fail" -eq 0 ]; then
  echo "FAIL: no hooks found in $HOOKS_DIR"
  fail=1
fi

echo ""
echo "passed: $pass, failed: $fail"
[ "$fail" -eq 0 ]
