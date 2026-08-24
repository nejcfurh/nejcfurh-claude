#!/usr/bin/env bash
# Regression tests for hooks/pre-bash-pipe-status-gate.sh — warns (never blocks)
# when a command whose exit status is load-bearing is piped into a filter, so the
# reported status belongs to the filter rather than the command.
#
# The load-bearing case here is SILENCE, not firing. Inspection pipelines
# (`git log | head`, `grep x | head`, `ls | tail`) are overwhelmingly the common
# shape, and a gate that comments on those becomes noise nobody reads — at which
# point it is worse than not existing. So most of this suite asserts quiet.
#
# Exit code is always 0: the fix is to add the status capture, not to refuse to
# run the command.
# Run: bash pre-bash-pipe-status-gate.test.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

cd "$(mktemp -d "${TMPDIR:-/tmp}/hooktest-cwd.XXXXXX")" || exit 1
SUT="$SCRIPT_DIR/../hooks/pre-bash-pipe-status-gate.sh"

pass=0
fail=0

# fires <name> <command> — expects advisory output AND exit 0
fires() {
  local name="$1" command="$2" out rc
  out=$(jq -n --arg cmd "$command" '{tool_input:{command:$cmd}}' | bash "$SUT" 2>/dev/null)
  rc=$?
  if [ -n "$out" ] && [ "$rc" = "0" ]; then
    echo "PASS: fires — $name"
    pass=$((pass + 1))
  else
    echo "FAIL: fires — $name (output=${#out} chars, exit $rc; expected output and exit 0)"
    fail=$((fail + 1))
  fi
}

# quiet <name> <command> — expects no output at all
quiet() {
  local name="$1" command="$2" out rc
  out=$(jq -n --arg cmd "$command" '{tool_input:{command:$cmd}}' | bash "$SUT" 2>/dev/null)
  rc=$?
  if [ -z "$out" ] && [ "$rc" = "0" ]; then
    echo "PASS: quiet — $name"
    pass=$((pass + 1))
  else
    echo "FAIL: quiet — $name (unexpected output: ${out:0:60})"
    fail=$((fail + 1))
  fi
}

# --- fires: verification commands whose status is the point -------------------
fires "test run into tail" 'npm run test | tail -5'
fires "test run with flags into tail" 'npm run test -- --maxWorkers=8 | tail -3'
fires "lint script into tail" 'npm run lint:check | tail -5'
fires "typecheck into head" 'npx tsc --noEmit | head -20'
fires "typecheck piped to grep -c" 'npx tsc --noEmit | grep -c "error TS"'
fires "install into tail" 'npm ci | tail -25'
fires "vitest into tail" 'vitest run | tail'
fires "playwright into tail" 'playwright test | tail -10'
fires "migration tool into tail" 'npx dbmate up | tail'
fires "db client into tail" 'psql -c "select 1" | tail -2'
fires "dump into wc" 'pg_dump --data-only | wc -l'
fires "build tool into tail" 'make build | tail -5'
fires "python tests into tail" 'pytest -q | tail -5'

# --- quiet: inspection pipelines, the common and correct shape ---------------
quiet "git log into head" 'git log --oneline | head -20'
quiet "git status into head" 'git status --porcelain | head -5'
quiet "grep into head" 'grep -rn foo src | head'
quiet "ls into tail" 'ls -la | tail -3'
quiet "cat into sed" 'cat file.txt | sed -n "1,20p"'
quiet "find into head" 'find . -name "*.ts" | head'
quiet "docker ps into head" 'docker ps -a | head -20'
quiet "lsof into head" 'lsof -nP -iTCP:3000 -sTCP:LISTEN | head -2'

# --- quiet: status already handled -------------------------------------------
quiet "pipefail set" 'set -o pipefail; npm run test | tail -5'
quiet "PIPESTATUS captured" 'npm run test | tail -5; echo "${PIPESTATUS[0]}"'

# --- quiet: no pipe into a filter at all -------------------------------------
quiet "redirected to a log then status echoed" 'npm run test > out.log 2>&1; echo "exit=$?"'
quiet "bare test run" 'npm run test'
quiet "piped into a non-filter" 'npm run build | cat'

# --- bypass -------------------------------------------------------------------
SKIP_BASH_PIPE_STATUS_GATE=1 quiet "SKIP env silences the gate" 'npm run test | tail -5'

echo
echo "passed: $pass, failed: $fail"
[ "$fail" -eq 0 ] || exit 1
