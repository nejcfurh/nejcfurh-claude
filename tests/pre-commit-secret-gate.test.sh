#!/usr/bin/env bash
# Regression tests for hooks/pre-commit-secret-gate.sh.
#
# Each case pipes a PreToolUse JSON payload into the hook from a throwaway
# repo and asserts on the exit code (0 = allowed, 2 = blocked). gitleaks is
# disabled via SECRET_GATE_SKIP_GITLEAKS so the built-in pattern scan is what
# gets exercised, machine-independently. Fixture secrets are assembled at
# runtime so this test file itself never contains a contiguous secret-shaped
# string. Run: bash pre-commit-secret-gate.test.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="$SCRIPT_DIR/../hooks/pre-commit-secret-gate.sh"

pass=0
fail=0

export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@test
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@test
export SECRET_GATE_SKIP_GITLEAKS=1
unset CLAUDE_PROJECT_DIR

# Secret-shaped fixtures, assembled so they never appear verbatim in this file.
fake_aws="AKIA$(printf 'IOSFODNN7EXAMPLE')"
fake_key_header="-----BEGIN RSA$(printf ' PRIVATE KEY')-----"
fake_anthropic="sk-ant-$(printf 'api03-abcdefghijklmnopqrstuvwx')"

make_repo() { # -> prints repo path (one initial commit, clean tree)
  local r
  r=$(mktemp -d "${TMPDIR:-/tmp}/hooktest.XXXXXX")
  (cd "$r" && git init -q -b feat/topic && git commit -q --allow-empty -m init)
  printf '%s\n' "$r"
}

run_case() { # run_case <name> <expected-exit> <cwd> <command-string>
  local name="$1" expected="$2" cwd="$3" command="$4" got
  jq -n --arg cmd "$command" '{tool_input:{command:$cmd}}' \
    | (cd "$cwd" && bash "$SUT") >/dev/null 2>&1
  got=$?
  if [ "$got" = "$expected" ]; then
    echo "PASS: $name (exit $got)"
    pass=$((pass + 1))
  else
    echo "FAIL: $name — expected exit $expected, got $got"
    fail=$((fail + 1))
  fi
}

# Staged AWS-style key blocks the commit.
r1=$(make_repo)
printf 'aws_key=%s\n' "$fake_aws" > "$r1/config.ts"
git -C "$r1" add config.ts
run_case "staged AWS key blocked" 2 "$r1" 'git commit -m "feat: x"'

# Unstaged tracked change with a private key header blocks — the command may
# stage it via `git add` right before committing.
r2=$(make_repo)
printf 'ok\n' > "$r2/notes.md"
git -C "$r2" add notes.md && git -C "$r2" commit -qm "docs: notes"
printf '%s\nabc\n' "$fake_key_header" >> "$r2/notes.md"
run_case "unstaged private key blocked" 2 "$r2" 'git add -A && git commit -m "docs: y"'

# Untracked file with an Anthropic-style key blocks.
r3=$(make_repo)
printf 'key=%s\n' "$fake_anthropic" > "$r3/scratch.txt"
run_case "untracked API key blocked" 2 "$r3" 'git add -A && git commit -m "chore: z"'

# Clean changes pass.
r4=$(make_repo)
printf 'const x = 1\n' > "$r4/clean.ts"
git -C "$r4" add clean.ts
run_case "clean staged change allowed" 0 "$r4" 'git commit -m "feat: x"'

# Regex-shaped text (a pattern, not a key) must not trip the scan.
r5=$(make_repo)
printf 'pattern = "AKIA[0-9A-Z]{16}"\n' > "$r5/scanner.ts"
git -C "$r5" add scanner.ts
run_case "regex text about keys allowed" 0 "$r5" 'git commit -m "feat: scanner"'

# Non-commit commands are ignored even with a secret in the tree.
run_case "non-commit command ignored" 0 "$r1" 'git status'

# git -C targets the repo with the secret from elsewhere.
run_case "git -C secret repo blocked from clean cwd" 2 "$r4" \
  "git -C $r1 commit -m \"feat: x\""

# Bypass env var must allow anything through.
jq -n --arg cmd 'git commit -m "feat: x"' '{tool_input:{command:$cmd}}' \
  | (cd "$r1" && SKIP_SECRET_GATE=1 bash "$SUT") >/dev/null 2>&1
if [ $? -eq 0 ]; then
  echo "PASS: bypass env allows commit (exit 0)"
  pass=$((pass + 1))
else
  echo "FAIL: bypass env allows commit — expected exit 0"
  fail=$((fail + 1))
fi

rm -rf "$r1" "$r2" "$r3" "$r4" "$r5"

echo ""
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
