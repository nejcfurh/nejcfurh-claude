#!/usr/bin/env bash
# Regression tests for hooks/pre-bash-zsh-modifier-gate.sh — warns (never
# blocks) when a zsh-run command expands an unbraced parameter followed by
# ":<letter>", which zsh applies as a history modifier.
#
# Half of this suite asserts silence: braced names, ports, paths after a
# colon and single-quoted text are all common and correct.
#
# Exit code is always 0.
# Run: bash pre-bash-zsh-modifier-gate.test.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

cd "$(mktemp -d "${TMPDIR:-/tmp}/hooktest-cwd.XXXXXX")" || exit 1
SUT="$SCRIPT_DIR/../hooks/pre-bash-zsh-modifier-gate.sh"

pass=0
fail=0

payload() {
  jq -n --arg cmd "$1" '{tool_input:{command:$cmd}}'
}

# fires <name> <command> [shell] — expects advisory output AND exit 0
fires() {
  local name="$1" out rc
  out=$(payload "$2" | SHELL="${3:-/bin/zsh}" bash "$SUT" 2>/dev/null)
  rc=$?
  if [ -n "$out" ] && [ "$rc" = "0" ]; then
    echo "PASS: fires — $name"
    pass=$((pass + 1))
  else
    echo "FAIL: fires — $name (output=${#out} chars, exit $rc; expected output and exit 0)"
    fail=$((fail + 1))
  fi
}

# quiet <name> <command> [shell] — expects no output at all
quiet() {
  local name="$1" out rc
  out=$(payload "$2" | SHELL="${3:-/bin/zsh}" bash "$SUT" 2>/dev/null)
  rc=$?
  if [ -z "$out" ] && [ "$rc" = "0" ]; then
    echo "PASS: quiet — $name"
    pass=$((pass + 1))
  else
    echo "FAIL: quiet — $name (unexpected output: ${out:0:60})"
    fail=$((fail + 1))
  fi
}

# --- fires: unbraced parameter + ":<modifier letter>" under zsh ---------------
fires "git show ref:path in double quotes" 'git show "$REF:lib/x.ts"'
fires "unquoted ref:path" 'git show $T:components/data.ts'
fires "head modifier" 'echo "$DIR:hidden"'
fires "absolute-path modifier" 'cp "$SRC:app/page.tsx" out/'
fires "positional parameter" 'git show "$1:readme.md"'
fires "modifier after a quoted segment" "echo 'fine' && git show \"\$REF:lib/y.ts\""

# --- quiet: braced or otherwise safe forms ------------------------------------
quiet "braced name before colon" 'git show "${REF}:lib/x.ts"'
quiet "default-value expansion" 'echo "${VAR:-fallback}"'
quiet "port after colon" 'curl "http://$HOST:8080/health"'
quiet "path after colon" 'export PATH="$PWD:/usr/bin"'
quiet "letter that is not a modifier" 'echo "$A:b"'
quiet "single-quoted text is not expanded" "echo '\$REF:lib/x.ts'"
quiet "no parameter at all" 'git fetch origin staging'

# --- quiet: not a zsh session -------------------------------------------------
quiet "bash session" 'git show "$REF:lib/x.ts"' /bin/bash

# --- bypass -------------------------------------------------------------------
SKIP_BASH_ZSH_MODIFIER_GATE=1 quiet "SKIP env silences the gate" 'git show "$REF:lib/x.ts"'

echo
echo "passed: $pass, failed: $fail"
[ "$fail" -eq 0 ] || exit 1
