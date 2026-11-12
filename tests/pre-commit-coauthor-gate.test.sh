#!/usr/bin/env bash
# Regression tests for hooks/pre-commit-coauthor-gate.sh.
# Run: bash pre-commit-coauthor-gate.test.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# A failed mktemp must never leak this suite's git commands into the real repo.
cd "$(mktemp -d "${TMPDIR:-/tmp}/hooktest-cwd.XXXXXX")" || exit 1
SUT="$SCRIPT_DIR/../hooks/pre-commit-coauthor-gate.sh"

pass=0
fail=0

run_case() { # run_case <name> <expected-exit> <command-string>
  local name="$1" expected="$2" command="$3" got
  jq -n --arg cmd "$command" '{tool_input:{command:$cmd}}' | bash "$SUT" >/dev/null 2>&1
  got=$?
  if [ "$got" = "$expected" ]; then
    echo "PASS: $name (exit $got)"
    pass=$((pass + 1))
  else
    echo "FAIL: $name — expected exit $expected, got $got"
    fail=$((fail + 1))
  fi
}

run_case "co-authored-by footer blocked" 2 \
  'git commit -m "feat: x

Co-Authored-By: Someone <noreply@example.com>"'

run_case "generated-with footer blocked (case-insensitive)" 2 \
  'git commit -m "feat: x

🤖 generated with claude"'

run_case "clean message allowed" 0 \
  'git commit -m "feat(auth): add login"'

run_case "non-commit command ignored" 0 \
  'echo "Co-Authored-By in a random echo"'

run_case "git -C form with attribution blocked" 2 \
  'git -C /some/repo commit -m "feat: x

Co-Authored-By: Someone <noreply@example.com>"'

# Git-level options sit between `git` and the subcommand, so the literal
# substring "git commit" this gate used to fall back to matched none of these.
run_case "--no-pager form with attribution blocked" 2 \
  'git --no-pager commit -m "feat: x

Co-Authored-By: Someone <noreply@example.com>"'

run_case "double-space form with attribution blocked" 2 \
  'git  commit -m "feat: x

Co-Authored-By: Someone <noreply@example.com>"'

run_case "--git-dir form with attribution blocked" 2 \
  'git --git-dir=.git commit -m "feat: x

🤖 Generated with Claude Code"'

run_payload() { # run_payload <name> <expected-exit> <json-payload>
  local name="$1" expected="$2" got
  printf '%s' "$3" | bash "$SUT" >/dev/null 2>&1
  got=$?
  if [ "$got" = "$expected" ]; then
    echo "PASS: $name (exit $got)"
    pass=$((pass + 1))
  else
    echo "FAIL: $name — expected exit $expected, got $got"
    fail=$((fail + 1))
  fi
}

# A message file is invisible in the command string, so `git commit -F <file>`
# carried a trailer straight past the gate.
msgdir=$(mktemp -d "${TMPDIR:-/tmp}/coauthor-msg.XXXXXX") || exit 1
printf 'feat: x\n\nCo-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>\n' > "$msgdir/bad.txt"
printf 'feat: x\n\nplain body\n' > "$msgdir/good.txt"

run_case "-F file with attribution blocked" 2 "git commit -F $msgdir/bad.txt"
run_case "-Fpath file with attribution blocked" 2 "git commit -F$msgdir/bad.txt"
run_case "--file= file with attribution blocked" 2 "git commit --file=$msgdir/bad.txt"
run_case "--file path with attribution blocked" 2 "git commit --file $msgdir/bad.txt"
run_case "-C dir with relative -F file blocked" 2 "git -C $msgdir commit -F bad.txt"
run_case "cd dir && relative -F file blocked" 2 "cd $msgdir && git commit -F bad.txt"
run_case "-F clean file allowed" 0 "git commit -F $msgdir/good.txt"
run_case "-F missing file allowed" 0 "git commit -F $msgdir/absent.txt"

# A message file the agent writes can be committed later through `!`, which runs
# in the user's shell where no agent hook fires — so check the file at write time.
write_payload() { # write_payload <tool> <field> <text>
  jq -n --arg t "$1" --arg f "$2" --arg v "$3" \
    '{tool_name:$t, tool_input:({file_path:"/x/COMMIT_MSG"} + {($f):$v})}'
}

run_payload "Write of a Claude trailer blocked" 2 \
  "$(write_payload Write content "$(printf 'feat: x\n\nCo-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>\n')")"
run_payload "Write of an Anthropic trailer blocked (case-insensitive)" 2 \
  "$(write_payload Write content "$(printf 'feat: x\n\nco-authored-by: Bot <noreply@ANTHROPIC.com>\n')")"
run_payload "Edit adding a generated-with footer blocked" 2 \
  "$(write_payload Edit new_string "$(printf 'body\n\n\360\237\244\226 Generated with [Claude Code](https://claude.com/claude-code)\n')")"
run_payload "Write with a human co-author allowed" 0 \
  "$(write_payload Write content "$(printf 'feat: x\n\nCo-Authored-By: Ana <ana@example.com>\n')")"
run_payload "Write of prose mentioning the trailer allowed" 0 \
  "$(write_payload Write content "$(printf 'Never add a \140Co-Authored-By: Claude\140 trailer or the "Generated with Claude Code" footer.\n')")"
run_payload "Write of a clean message allowed" 0 \
  "$(write_payload Write content "$(printf 'feat: x\n\nplain body\n')")"

write_bad=$(write_payload Write content "$(printf 'x\nCo-Authored-By: Claude <noreply@anthropic.com>\n')")
if printf '%s' "$write_bad" | SKIP_COAUTHOR_GATE=1 bash "$SUT" >/dev/null 2>&1; then
  echo "PASS: bypass env allows a Write (exit 0)"
  pass=$((pass + 1))
else
  echo "FAIL: bypass env allows a Write — expected exit 0"
  fail=$((fail + 1))
fi

# Bypass env var must allow anything through.
jq -n --arg cmd 'git commit -m "x Co-Authored-By: y"' '{tool_input:{command:$cmd}}' \
  | SKIP_COAUTHOR_GATE=1 bash "$SUT" >/dev/null 2>&1
if [ $? -eq 0 ]; then
  echo "PASS: bypass env allows anything (exit 0)"
  pass=$((pass + 1))
else
  echo "FAIL: bypass env allows anything — expected exit 0"
  fail=$((fail + 1))
fi

echo ""
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
