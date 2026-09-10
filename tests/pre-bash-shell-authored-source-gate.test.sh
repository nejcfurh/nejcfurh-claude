#!/usr/bin/env bash
# Regression tests for hooks/pre-bash-shell-authored-source-gate.sh — warns
# (never blocks) when a shell command authors a source file, because whatever
# the project hangs off the editing tools did not see it.
#
# The load-bearing case here is SILENCE. Redirects are in most shell commands
# ever run, so a gate that comments on logs, scratch scripts, pipes or non-source
# targets is noise nobody reads. Every "quiet" case below is a shape that
# contains a redirect, a heredoc or a source extension and must still say
# nothing.
#
# Exit code is always 0: authoring through the shell is often the right call.
# The fix is to run the formatter afterwards, not to refuse the redirect.
# Run: bash pre-bash-shell-authored-source-gate.test.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="$SCRIPT_DIR/../hooks/pre-bash-shell-authored-source-gate.sh"

cd "$(mktemp -d "${TMPDIR:-/tmp}/hooktest-cwd.XXXXXX")" || exit 1

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

# --- fires: the shapes that skip the on-edit hooks ---------------------------
fires "heredoc into a .ts file" "cat > lib/foo.ts <<'EOF'
export const a = 1
EOF"
fires "append redirect into a .tsx file" 'echo "export {}" >> components/b.tsx'
fires "truncating redirect into a .js file" 'node gen.js > src/generated.js'
fires "python write_text on a .tsx file" "python3 -c \"from pathlib import Path; Path('lib/a.tsx').write_text(src)\""
fires "node writeFileSync on a .ts file" "node -e \"require('fs').writeFileSync('lib/a.ts', body)\""
fires "stylesheet target" 'cat theme.tpl > styles/theme.css'
fires "scss target" 'echo "\$c: red" > styles/_vars.scss'
fires "single-file component target" 'printf "<template/>" > src/App.vue'
fires "svelte target" 'printf "<div/>" > src/App.svelte'
fires "esm/cjs targets" 'echo "export default {}" > config/a.mjs'

# --- quiet: scratch paths are where throwaway scripts belong ------------------
quiet "temp dir absolute" 'cat > /tmp/claude/probe.ts <<EOF
x
EOF'
quiet "private temp dir" 'echo x > /private/tmp/claude/probe.tsx'
quiet "TMPDIR" 'node -e "x" > $TMPDIR/probe.js'
quiet "scratchpad" 'echo x > /session/scratchpad/probe.ts'

# --- quiet: redirects that are not authoring source --------------------------
quiet "log file" 'npm run test > out.log 2>&1'
quiet "pipe into a pager" 'git log --oneline | head -5'
quiet "markdown target" 'cat > NOTES.md <<EOF
notes
EOF'
quiet "json target" 'jq . a.json > b.json'
quiet "stderr redirect only" 'npx tsc --noEmit 2>/dev/null'
quiet "no redirect at all" 'ls components/'
quiet "reading a source file" 'cat lib/foo.ts'
quiet "grep whose pattern contains an arrow" 'grep -rn "=>" src/foo.ts'
quiet "heredoc carrying no source path" 'psql <<EOF
select 1;
EOF'
# Every false positive in a 6969-command replay of real sessions was this one
# shape: hunting merge-conflict markers in a source file.
quiet "grep for conflict markers in a source file" "grep -n -A30 '^<<<<<<<' hooks/useGuard.ts | head -70"
quiet "conflict-marker count across sources" "grep -c '^<<<<<<<' app/page.tsx components/a.tsx"

# --- bypass -------------------------------------------------------------------
out=$(jq -n --arg cmd 'echo x > lib/a.ts' '{tool_input:{command:$cmd}}' |
  SKIP_SHELL_AUTHORED_SOURCE_GATE=1 bash "$SUT" 2>/dev/null)
if [ -z "$out" ]; then
  echo "PASS: quiet — SKIP env silences the gate"
  pass=$((pass + 1))
else
  echo "FAIL: quiet — SKIP env silences the gate (unexpected output)"
  fail=$((fail + 1))
fi

# --- malformed payloads must not error ---------------------------------------
out=$(printf '%s' 'not json at all >lib/a.ts' | bash "$SUT" 2>/dev/null)
rc=$?
if [ -z "$out" ] && [ "$rc" = "0" ]; then
  echo "PASS: quiet — non-JSON payload"
  pass=$((pass + 1))
else
  echo "FAIL: quiet — non-JSON payload (output=${#out} chars, exit $rc)"
  fail=$((fail + 1))
fi

out=$(printf '' | bash "$SUT" 2>/dev/null)
rc=$?
if [ -z "$out" ] && [ "$rc" = "0" ]; then
  echo "PASS: quiet — empty payload"
  pass=$((pass + 1))
else
  echo "FAIL: quiet — empty payload (output=${#out} chars, exit $rc)"
  fail=$((fail + 1))
fi

echo
echo "passed: $pass, failed: $fail"
[ "$fail" -eq 0 ] || exit 1
