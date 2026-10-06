#!/usr/bin/env bash
# Regression tests for hooks/pre-pr-stack-base-gate.sh — refuses `gh pr create
# --base <B>` when <B> is the head branch of an open PR, because that PR belongs
# in a registered `gh stack`, not a hand-made chain.
#
# `gh` is stubbed through GH_BIN: the stub answers `pr list --head feature-a`
# with PR 41 and every other head with nothing, and logs its arguments so the
# --repo pass-through can be checked. The quiet cases matter as much as the
# blocking ones: most `gh pr create` calls target the default branch or a trunk,
# and a gate that fires on those would block every PR.
# Run: bash pre-pr-stack-base-gate.test.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="$SCRIPT_DIR/../hooks/pre-pr-stack-base-gate.sh"

pass=0
fail=0

command -v jq >/dev/null 2>&1 || {
  echo "SKIP: jq is required to build payloads"
  exit 0
}

stub_dir=$(mktemp -d "${TMPDIR:-/tmp}/stackbase.XXXXXX") || exit 1
trap 'rm -rf "$stub_dir"' EXIT
log="$stub_dir/gh.log"
cat >"$stub_dir/gh" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$log"
case " \$* " in
  *" --head feature-a "*) echo 41 ;;
  *" --head broken "*) exit 1 ;;
esac
exit 0
STUB
chmod +x "$stub_dir/gh"
export GH_BIN="$stub_dir/gh"

run() { jq -n --arg cmd "$1" '{tool_input:{command:$cmd}}' | bash "$SUT" 2>&1; }

# blocks <name> <command> — expects exit 2 and an explanation naming the PR
blocks() {
  local name="$1" command="$2" out rc
  out=$(run "$command")
  rc=$?
  if [ "$rc" = "2" ] && printf '%s' "$out" | grep -q '#41'; then
    echo "PASS: blocks — $name"
    pass=$((pass + 1))
  else
    echo "FAIL: blocks — $name (rc=$rc, output: ${out:-none})"
    fail=$((fail + 1))
  fi
}

# quiet <name> <command> — expects exit 0 and total silence
quiet() {
  local name="$1" command="$2" out rc
  out=$(run "$command")
  rc=$?
  if [ "$rc" = "0" ] && [ -z "$out" ]; then
    echo "PASS: quiet — $name"
    pass=$((pass + 1))
  else
    echo "FAIL: quiet — $name (rc=$rc, output: ${out:-none})"
    fail=$((fail + 1))
  fi
}

# --- blocks: the base is an open PR's head branch ------------------------------
blocks "--base <branch>" 'gh pr create --base feature-a --title "feat: b" --body-file /tmp/b.md'
blocks "--base=<branch>" 'gh pr create --base=feature-a --fill'
blocks "-B <branch>" 'gh pr create -B feature-a --fill'
blocks "quoted base" "gh pr create --base 'feature-a' --fill"
blocks "after cd &&" 'cd /repo && gh pr create --base feature-a --fill'
blocks "env prefix" 'GH_PROMPT_DISABLED=1 gh pr create --base feature-a --fill'

# --- quiet: not a stack, or not answerable ---------------------------------------
quiet "no --base (default branch)" 'gh pr create --title "feat: a" --fill'
quiet "trunk base" 'gh pr create --base staging --fill'
quiet "lookup fails" 'gh pr create --base broken --fill'
quiet "base only in the title" 'gh pr create --title "move to --base feature-a" --base staging'
quiet "base only in a heredoc body" "gh pr create --base staging --body-file - <<'EOF'
stacked on --base feature-a
EOF"
quiet "not pr create" 'gh pr list --base feature-a'
quiet "pr create only in an echo" 'echo "gh pr create --base feature-a"'

out=$(jq -n --arg cmd 'gh pr create --base feature-a --fill' '{tool_input:{command:$cmd}}' \
  | SKIP_PR_STACK_BASE_GATE=1 bash "$SUT" 2>&1)
if [ $? = 0 ] && [ -z "$out" ]; then
  echo "PASS: quiet — bypass variable"
  pass=$((pass + 1))
else
  echo "FAIL: quiet — bypass variable"
  fail=$((fail + 1))
fi

# --- the lookup targets the repo the PR is created in ---------------------------
: >"$log"
run 'gh pr create -R owner/other --base staging --fill' >/dev/null
if grep -q -- '--repo owner/other' "$log"; then
  echo "PASS: --repo is passed to the lookup"
  pass=$((pass + 1))
else
  echo "FAIL: --repo is passed to the lookup (log: $(cat "$log"))"
  fail=$((fail + 1))
fi

echo
echo "pre-pr-stack-base-gate: $pass passed, $fail failed"
[ "$fail" = 0 ]
