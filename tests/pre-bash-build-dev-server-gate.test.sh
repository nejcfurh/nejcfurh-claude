#!/usr/bin/env bash
# Regression tests for hooks/pre-bash-build-dev-server-gate.sh — warns (never
# blocks) when a production build is about to overwrite the output dir a live
# dev server is serving from.
#
# The load-bearing case here is SILENCE. Builds with nothing running are the
# overwhelmingly common shape, and so are dev/watch invocations that share the
# dir on purpose. A gate that comments on those becomes noise nobody reads.
#
# Port state is injected via BUILD_GATE_DEV_PORTS so the suite never depends on
# whatever happens to be listening on the machine running it: "fires" cases point
# at a real listener this test opens, "quiet" cases point at a closed port.
#
# Exit code is always 0: the fix is to stop the server or redirect the build, not
# to refuse to run it.
# Run: bash pre-bash-build-dev-server-gate.test.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="$SCRIPT_DIR/../hooks/pre-bash-build-dev-server-gate.sh"

cd "$(mktemp -d "${TMPDIR:-/tmp}/hooktest-cwd.XXXXXX")" || exit 1

pass=0
fail=0

# A port nothing is on. Chosen high and fixed; the quiet cases only need the
# gate's lsof probe to come back empty.
CLOSED_PORT=59137

# Open a real listener so the "fires" path exercises the actual lsof probe
# rather than a stubbed one. Without python3 the fires cases are skipped rather
# than silently passing.
LISTENER_PID=""
OPEN_PORT=""
if command -v python3 >/dev/null 2>&1 && command -v lsof >/dev/null 2>&1; then
  python3 -c '
import socket, sys, time
s = socket.socket()
s.bind(("127.0.0.1", 0))
s.listen(1)
sys.stderr.write(str(s.getsockname()[1]) + "\n")
sys.stderr.flush()
time.sleep(120)
' 2>"$PWD/.port" &
  LISTENER_PID=$!
  for _ in $(seq 1 40); do
    [ -s "$PWD/.port" ] && break
    sleep 0.1
  done
  OPEN_PORT=$(cat "$PWD/.port" 2>/dev/null | tr -d '[:space:]')
fi

cleanup() { [ -n "$LISTENER_PID" ] && kill "$LISTENER_PID" 2>/dev/null; }
trap cleanup EXIT

# fires <name> <command> — expects advisory output AND exit 0
fires() {
  local name="$1" command="$2" out rc
  if [ -z "$OPEN_PORT" ]; then
    echo "SKIP: fires — $name (no python3/lsof to open a listener)"
    return
  fi
  out=$(jq -n --arg cmd "$command" '{tool_input:{command:$cmd}}' |
    BUILD_GATE_DEV_PORTS="$OPEN_PORT" bash "$SUT" 2>/dev/null)
  rc=$?
  if [ -n "$out" ] && [ "$rc" = "0" ]; then
    echo "PASS: fires — $name"
    pass=$((pass + 1))
  else
    echo "FAIL: fires — $name (output=${#out} chars, exit $rc; expected output and exit 0)"
    fail=$((fail + 1))
  fi
}

# quiet <name> <command> [port] — expects no output at all
quiet() {
  local name="$1" command="$2" port="${3:-$CLOSED_PORT}" out rc
  out=$(jq -n --arg cmd "$command" '{tool_input:{command:$cmd}}' |
    BUILD_GATE_DEV_PORTS="$port" bash "$SUT" 2>/dev/null)
  rc=$?
  if [ -z "$out" ] && [ "$rc" = "0" ]; then
    echo "PASS: quiet — $name"
    pass=$((pass + 1))
  else
    echo "FAIL: quiet — $name (unexpected output: ${out:0:60})"
    fail=$((fail + 1))
  fi
}

# --- fires: a production build while something is listening -------------------
fires "npm run build" 'npm run build'
fires "yarn build" 'yarn run build'
fires "pnpm build" 'pnpm run build'
fires "next build" 'npx next build'
fires "vite build" 'npx vite build'
fires "astro build" 'astro build'
fires "turbo build" 'turbo run build'
fires "build with a redirect" 'npm run build > out.log 2>&1'

# --- quiet: nothing listening, which is the ordinary case ---------------------
quiet "npm run build, no dev server" 'npm run build'
quiet "next build, no dev server" 'npx next build'

# --- quiet: dev and watch invocations share the dir deliberately --------------
quiet "npm run dev" 'npm run dev' "$OPEN_PORT"
quiet "next dev" 'npx next dev' "$OPEN_PORT"
quiet "vite build --watch" 'npx vite build --watch' "$OPEN_PORT"

# --- quiet: not a build at all ------------------------------------------------
quiet "test run" 'npm run test' "$OPEN_PORT"
quiet "install" 'npm ci' "$OPEN_PORT"
quiet "typecheck" 'npx tsc --noEmit' "$OPEN_PORT"
quiet "grep for the word build" 'grep -rn build src' "$OPEN_PORT"
quiet "docker build is not a JS bundle" 'docker build -t app .' "$OPEN_PORT"

# --- bypass -------------------------------------------------------------------
if [ -n "$OPEN_PORT" ]; then
  out=$(jq -n --arg cmd 'npm run build' '{tool_input:{command:$cmd}}' |
    SKIP_BUILD_DEV_SERVER_GATE=1 BUILD_GATE_DEV_PORTS="$OPEN_PORT" bash "$SUT" 2>/dev/null)
  if [ -z "$out" ]; then
    echo "PASS: quiet — SKIP env silences the gate"
    pass=$((pass + 1))
  else
    echo "FAIL: quiet — SKIP env silences the gate (unexpected output)"
    fail=$((fail + 1))
  fi
fi

echo
echo "passed: $pass, failed: $fail"
[ "$fail" -eq 0 ] || exit 1
