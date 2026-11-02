#!/usr/bin/env bash
# Regression tests for hooks/pre-bash-gh-sandbox-gate.sh — warns (never
# blocks) when `gh` runs INSIDE the sandbox, where it cannot read its own
# config and fails or returns nothing.
#
# Much of this suite asserts silence: gh outside the sandbox is correct, and
# "gh" inside another word or a path is not an invocation.
#
# Exit code is always 0.
# Run: bash pre-bash-gh-sandbox-gate.test.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

cd "$(mktemp -d "${TMPDIR:-/tmp}/hooktest-cwd.XXXXXX")" || exit 1
SUT="$SCRIPT_DIR/../hooks/pre-bash-gh-sandbox-gate.sh"

pass=0
fail=0

# is_context <output> — true when the hook spoke in the JSON envelope Claude
# Code feeds to the model. Plain stdout from a PreToolUse hook that exits 0 is
# shown only in the transcript, so a warning printed that way never reaches the
# model; "some output" is not enough to count as firing.
is_context() {
  printf '%s' "$1" | jq -e \
    '.hookSpecificOutput.hookEventName == "PreToolUse" and (.hookSpecificOutput.additionalContext | length > 0)' \
    >/dev/null 2>&1
}

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
  if is_context "$out" && [ "$rc" = "0" ]; then
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

# --- fires: gh invoked inside the sandbox --------------------------------------
fires "gh at the start, sandbox flag false" 'gh pr list --state open' false
fires "gh at the start, sandbox flag absent" 'gh pr view 107 --json state' absent
fires "gh after cd &&" 'cd /repo && gh pr create --base main --body-file /abs/b.md' false
fires "gh after a pipe" 'echo x | gh api repos/o/r/pulls' false
fires "gh inside command substitution" 'n=$(gh pr list --json number --jq length)' false
fires "gh after a semicolon" 'git fetch; gh run list' false

# --- quiet: gh outside the sandbox, the correct form ---------------------------
quiet "unsandboxed gh" 'gh pr list --state open' true
quiet "unsandboxed gh after cd" 'cd /repo && gh pr view 1' true

# --- quiet: no gh invocation ---------------------------------------------------
quiet "gh inside a path" 'ls ~/.config/gh/ -la' false
quiet "gh inside a word" 'echo "high ground"' false
quiet "gh as an argument, not a command" 'git log --grep "gh stack"' false
quiet "plain git" 'git status -sb' false

# --- bypass ---------------------------------------------------------------------
SKIP_BASH_GH_SANDBOX_GATE=1 quiet "SKIP env silences the gate" 'gh pr list' false

# --- git push through gh's credential helper -------------------------------------
# Fixtures run under an isolated HOME with system config off, so the developer's
# own credential helpers cannot decide a case.
FIX=$(mktemp -d "${TMPDIR:-/tmp}/ghpush.XXXXXX") || exit 1
trap 'rm -rf "$FIX"' EXIT
mkdir -p "$FIX/home" "$FIX/ghhome" "$FIX/nowhere"
gitf() { HOME="$FIX/home" GIT_CONFIG_NOSYSTEM=1 git "$@"; }
mkrepo() { # mkrepo <dir> <origin-url> <https-helper>
  gitf init -q "$1" && gitf -C "$1" remote add origin "$2"
  [ -n "$3" ] && gitf -C "$1" config credential.https://github.com.helper "$3"
  return 0
}
mkrepo "$FIX/gh" https://github.com/o/r.git '!gh auth git-credential'
mkrepo "$FIX/keychain" https://github.com/o/r.git osxkeychain
mkrepo "$FIX/ssh" git@github.com:o/r.git '!gh auth git-credential'
HOME="$FIX/ghhome" git config --global credential.https://github.com.helper '!gh auth git-credential'

# push_case <fires|quiet> <name> <cwd> <command> <unsandboxed> [home]
push_case() {
  local want="$1" name="$2" wd="$3" out rc
  out=$(payload "$4" "$5" | (cd "$wd" && HOME="${6:-$FIX/home}" GIT_CONFIG_NOSYSTEM=1 bash "$SUT" 2>/dev/null))
  rc=$?
  if { [ "$want" = fires ] && is_context "$out"; } || { [ "$want" = quiet ] && [ -z "$out" ]; }; then
    [ "$rc" = "0" ] && { echo "PASS: $want — $name"; pass=$((pass + 1)); return; }
  fi
  echo "FAIL: $want — $name (output=${#out} chars, exit $rc)"
  fail=$((fail + 1))
}

push_case fires "push to origin with gh as the https helper" "$FIX/gh" 'git push origin feat/x' false
push_case fires "push with no remote defaults to origin" "$FIX/gh" 'git push' absent
push_case fires "push after cd into the repo" "$FIX/nowhere" "cd $FIX/gh && git push -u origin feat/x" false
push_case fires "push with -C" "$FIX/nowhere" "git -C $FIX/gh push --force-with-lease" false
push_case fires "an option value is not taken for the remote" "$FIX/gh" 'git push -o ci.skip origin feat/x' false
push_case fires "explicit https url, helper set globally" "$FIX/nowhere" 'git push https://github.com/o/r.git feat/x' false "$FIX/ghhome"

push_case quiet "unsandboxed push" "$FIX/gh" 'git push origin feat/x' true
push_case quiet "a helper other than gh" "$FIX/keychain" 'git push origin feat/x' false
push_case quiet "an ssh remote uses no credential helper" "$FIX/ssh" 'git push origin feat/x' false
push_case quiet "git push only inside a commit message" "$FIX/gh" 'git commit -m "then git push"' false
push_case quiet "stash push is not a push" "$FIX/gh" 'git stash push -- a.txt' false
push_case quiet "an unknown remote resolves to nothing" "$FIX/gh" 'git push nosuchremote feat/x' false

echo
echo "passed: $pass, failed: $fail"
[ "$fail" -eq 0 ] || exit 1
