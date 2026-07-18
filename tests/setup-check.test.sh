#!/usr/bin/env bash
# Regression tests for scripts/setup.sh — the installer that symlinks this
# repo into ~/.claude. Runs against a throwaway CLAUDE_CONFIG_DIR; PATH is
# restricted to system dirs so the `claude` plugin-install step never runs
# against the real machine state.
# Run: bash setup-check.test.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$(mktemp -d "${TMPDIR:-/tmp}/hooktest-cwd.XXXXXX")" || exit 1
SUT="$REPO_ROOT/scripts/setup.sh"

pass=0
fail=0

check() { # check <name> <condition-result>
  local name="$1" rc="$2"
  if [ "$rc" -eq 0 ]; then
    echo "PASS: $name"
    pass=$((pass + 1))
  else
    echo "FAIL: $name"
    fail=$((fail + 1))
  fi
}

run_setup() { # run_setup <target-dir> [--check]
  local tgt="$1"; shift
  CLAUDE_CONFIG_DIR="$tgt" PATH=/usr/bin:/bin bash "$SUT" "$@"
}

# --check is a true dry run: nothing appears in the target.
tgt=$(mktemp -d "${TMPDIR:-/tmp}/hooktest-tgt.XXXXXX")
run_setup "$tgt" --check >/dev/null 2>&1
rc=$?
{ [ "$rc" -eq 0 ] && [ -z "$(ls -A "$tgt")" ]; } && rc=0 || rc=1
check "--check exits 0 and creates nothing" "$rc"

# Apply links every repo item into the target.
out=$(run_setup "$tgt" 2>&1)
rc=1
if [ -L "$tgt/CLAUDE.md" ] \
  && [ "$(readlink "$tgt/CLAUDE.md")" = "$REPO_ROOT/CLAUDE.md" ] \
  && [ -L "$tgt/hooks" ] && [ -L "$tgt/settings.json" ]; then
  rc=0
fi
check "apply symlinks CLAUDE.md, hooks, settings.json into target" "$rc"

# Re-running is idempotent.
out=$(run_setup "$tgt" 2>&1)
case "$out" in *"already linked"*) rc=0 ;; *) rc=1 ;; esac
check "re-run reports already linked" "$rc"

# An existing real file is backed up, then linked.
tgt2=$(mktemp -d "${TMPDIR:-/tmp}/hooktest-tgt.XXXXXX")
echo "user content" > "$tgt2/CLAUDE.md"
run_setup "$tgt2" >/dev/null 2>&1
rc=1
if [ -L "$tgt2/CLAUDE.md" ] && ls "$tgt2"/CLAUDE.md.bak.* >/dev/null 2>&1; then
  rc=0
fi
check "existing real file is backed up before linking" "$rc"
rm -rf "$tgt2"

# A link we own whose repo source is gone gets removed (e.g. commands/ after
# its migration into skills/) — a foreign file in the same spot is untouched.
ln -s "$REPO_ROOT/commands" "$tgt/commands"
out=$(run_setup "$tgt" 2>&1)
rc=1
case "$out" in *"UNLINK  commands"*) [ ! -e "$tgt/commands" ] && [ ! -L "$tgt/commands" ] && rc=0 ;; esac
check "dangling managed link is unlinked (said UNLINK: $rc)" "$rc"
rm -rf "$tgt"

echo ""
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
