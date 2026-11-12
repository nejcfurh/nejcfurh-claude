#!/usr/bin/env bash
# Regression tests for hooks/pre-bash-zsh-modifier-gate.sh. Under zsh it
# BLOCKS an unquoted word zsh will reject (`--include=*.ts`, `echo ====`) and
# WARNS on an unbraced parameter followed by ":<letter>", which zsh applies as
# a history modifier.
#
# Most of this suite asserts silence: quoted patterns, here-document bodies,
# [[ ]] comparisons, braced names, ports and single-quoted text are all common
# and correct.
#
# Exits non-zero when any case fails.
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

# A PreToolUse warning reaches the model only as additionalContext in the JSON
# envelope; plain stdout lands in the transcript alone.
is_envelope() {
  printf '%s' "$1" | jq -e \
    '.hookSpecificOutput.hookEventName == "PreToolUse" and (.hookSpecificOutput.additionalContext | length > 0)' \
    >/dev/null 2>&1
}

# fires <name> <command> [shell] — expects an additionalContext envelope AND exit 0
fires() {
  local name="$1" out rc
  out=$(payload "$2" | SHELL="${3:-/bin/zsh}" bash "$SUT" 2>/dev/null)
  rc=$?
  if is_envelope "$out" && [ "$rc" = "0" ]; then
    echo "PASS: fires — $name"
    pass=$((pass + 1))
  else
    echo "FAIL: fires — $name (output=${#out} chars, exit $rc; expected a PreToolUse additionalContext envelope and exit 0)"
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

# blocks <name> <command> — expects exit 2, a BLOCKED message, and no stdout
blocks() {
  local name="$1" out err rc errf
  errf=$(mktemp "${TMPDIR:-/tmp}/zshgate-err.XXXXXX")
  out=$(payload "$2" | SHELL=/bin/zsh bash "$SUT" 2>"$errf")
  rc=$?
  err=$(cat "$errf"); rm -f "$errf"
  if [ "$rc" = "2" ] && [ -z "$out" ] && printf '%s' "$err" | grep -q '^BLOCKED: zsh will abort'; then
    echo "PASS: blocks — $name"
    pass=$((pass + 1))
  else
    echo "FAIL: blocks — $name (exit $rc, stderr: ${err:0:80})"
    fail=$((fail + 1))
  fi
}

# --- blocks: zsh rejects the word before running anything after it -----------
blocks "grep --include glob" 'grep -rn foo --include=*.ts .'
blocks "second --include after a quoted one" "grep -rn x --include='*.ts' --include=*.tsx ."
blocks "--exclude glob" 'grep -rn x --exclude=*.lock .'
blocks "bracket glob after =" 'git log --format=[ab] -1'
blocks "short option with = and glob" 'mvn -Dtest=*IT verify'
blocks "glob after an && chain" 'git fetch -q && grep -rln x --include=*.md .'
blocks "inside unquoted command substitution" 'echo $(grep -l x --include=*.ts -r .)'
blocks "echo ==== separator" 'git status; echo ====; git log -1'
blocks "== in single-bracket test" '[ "$a" == "$b" ] && echo same'
blocks "==word" 'echo ===MERGED'
blocks "after a here-document body ends" "$(printf 'cat <<EOF
body
EOF
echo ====')"

# --- quiet: forms zsh accepts --------------------------------------------------
quiet "single-quoted glob" "grep -rn x --include='*.ts' ."
quiet "double-quoted glob" 'grep -rn x --include="*.ts" .'
quiet "escaped glob" 'grep -rn x --include=\*.ts .'
quiet "whole word quoted" 'grep -rn x "--include=*.ts" .'
quiet "option with = and no glob" 'git log --format=%h --exclude=node_modules -1'
quiet "glob in a non-option word" 'ls src/*.ts'
quiet "assignment with a glob" 'P=*.ts; echo "$P"'
quiet "parameter expansion after =" 'echo --x=${VAR:-*}'
quiet "bare =" '[ "$a" = "$b" ] && echo same'
quiet "=cmd is valid zsh" 'echo =ls'
quiet "== inside [[ ]]" '[[ "$a" == "$b" ]] && echo same'
quiet "== inside (( ))" 'if (( a == b )); then echo same; fi'
quiet "== inside arithmetic expansion" 'echo $(( 1 == 1 ))'
quiet "single-quoted ====" "echo '===='"
quiet "awk program in quotes" "awk '\$1 == 2' f.txt"
quiet "jq filter without leading ==" 'jq .a==1 f.json'
quiet "here-document body is data" "$(printf 'cat > f.md <<EOF
grep --include=*.ts
====
EOF
echo done')"
quiet "quoted here-document body is data" "$(printf "python3 - <<'PY'
print('==' * 4)
PY")"
quiet "indented <<- body" "$(printf 'cat <<-EOF
	====
	EOF
echo ok')"
quiet "multi-line commit message" "$(printf 'git commit -m "feat: x

==== --include=*.ts"')"
quiet "here-string is not a here-document" 'cat <<< "x"; echo ok'
quiet "comment" "$(printf 'ls # see ====
echo ok')"
quiet "nomatch disabled in the command" 'setopt nonomatch; grep -rn x --include=*.ts .'
quiet "bash session" 'grep -rn x --include=*.ts .' /bin/bash
SKIP_BASH_ZSH_GLOB_GATE=1 quiet "SKIP_BASH_ZSH_GLOB_GATE silences the block" 'echo ===='

# --- fires: unbraced parameter + ":<modifier letter>" under zsh ---------------
fires "git show ref:path in double quotes" 'git show "$REF:lib/x.ts"'
fires "unquoted ref:path" 'git show $T:components/data.ts'
fires "head modifier" 'echo "$DIR:hidden"'
fires "absolute-path modifier" 'cp "$SRC:app/page.tsx" out/'
fires "positional parameter" 'git show "$1:readme.md"'
fires "modifier after an assignment" 'X=1 git show "$REF:lib/x.ts"'
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
