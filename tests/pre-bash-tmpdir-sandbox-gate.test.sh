#!/usr/bin/env bash
# Regression tests for hooks/pre-bash-tmpdir-sandbox-gate.sh — warns (never
# blocks) when an UNSANDBOXED command names $TMPDIR, since the sandboxed and
# unsandboxed shells resolve it to different directories.
#
# Most of this suite asserts silence. Sandboxed commands use $TMPDIR all the
# time and correctly; a gate that commented on them would be read by nobody.
#
# Exit code is always 0.
# Run: bash pre-bash-tmpdir-sandbox-gate.test.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

cd "$(mktemp -d "${TMPDIR:-/tmp}/hooktest-cwd.XXXXXX")" || exit 1
SUT="$SCRIPT_DIR/../hooks/pre-bash-tmpdir-sandbox-gate.sh"

pass=0
fail=0

payload() {
  local command="$1" unsandboxed="$2"
  if [ "$unsandboxed" = "absent" ]; then
    jq -n --arg cmd "$command" '{tool_input:{command:$cmd}}'
  else
    jq -n --arg cmd "$command" --argjson u "$unsandboxed" '{tool_input:{command:$cmd, dangerouslyDisableSandbox:$u}}'
  fi
}

# fires <name> <command> <unsandboxed> — expects advisory output AND exit 0
fires() {
  local name="$1" out rc
  out=$(payload "$2" "$3" | bash "$SUT" 2>/dev/null)
  rc=$?
  if [ -n "$out" ] && [ "$rc" = "0" ]; then
    echo "PASS: fires — $name"
    pass=$((pass + 1))
  else
    echo "FAIL: fires — $name (output=${#out} chars, exit $rc; expected output and exit 0)"
    fail=$((fail + 1))
  fi
}

# quiet <name> <command> <unsandboxed> — expects no output at all
quiet() {
  local name="$1" out rc
  out=$(payload "$2" "$3" | bash "$SUT" 2>/dev/null)
  rc=$?
  if [ -z "$out" ] && [ "$rc" = "0" ]; then
    echo "PASS: quiet — $name"
    pass=$((pass + 1))
  else
    echo "FAIL: quiet — $name (unexpected output: ${out:0:60})"
    fail=$((fail + 1))
  fi
}

# --- fires: unsandboxed commands that name $TMPDIR ----------------------------
fires "log redirected into TMPDIR" 'gh run view 1 --log-failed > "$TMPDIR/deploy.log"' true
fires "braced TMPDIR" 'curl -s https://example.com -o "${TMPDIR}/page.html"' true
fires "TMPDIR with a default" 'mkdir -p "${TMPDIR:-/tmp}/work"' true
fires "reading back from TMPDIR" 'sed -n "1,20p" "$TMPDIR/deploy.log"' true
fires "tool flag pointing into TMPDIR" 'npm install --cache "$TMPDIR/npmcache"' true

# --- quiet: sandboxed commands, the common and correct case -------------------
quiet "sandboxed redirect into TMPDIR" 'echo hi > "$TMPDIR/x.txt"' false
quiet "sandbox flag absent" 'cat "$TMPDIR/x.txt"' absent
quiet "sandboxed braced TMPDIR" 'ls "${TMPDIR}"' false

# --- quiet: unsandboxed, but no TMPDIR in the command -------------------------
quiet "unsandboxed absolute path" 'gh run view 1 --log-failed > /abs/scratch/deploy.log' true
quiet "unsandboxed plain command" 'git fetch origin' true
quiet "unsandboxed word that only contains the letters" 'echo TMPDIRECTORY' true

# --- bypass -------------------------------------------------------------------
SKIP_BASH_TMPDIR_SANDBOX_GATE=1 quiet "SKIP env silences the gate" 'cat "$TMPDIR/x"' true

echo
echo "passed: $pass, failed: $fail"
[ "$fail" -eq 0 ] || exit 1
