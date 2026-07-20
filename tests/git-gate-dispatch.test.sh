#!/usr/bin/env bash
# Regression tests for hooks/git-gate-dispatch.sh — the single PreToolUse
# entry point that routes git commands to the individual gates. These cases
# assert ROUTING: each gate family is reachable through the dispatcher, a
# gate's block propagates as exit 2, SKIP_* bypasses reach the child gates,
# and the state-refresh context envelope only reaches stdout when nothing
# blocked. The gates' own behavior is covered by their dedicated suites.
# Run: bash git-gate-dispatch.test.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# A failed mktemp must never leak this suite's git commands into the real repo.
cd "$(mktemp -d "${TMPDIR:-/tmp}/hooktest-cwd.XXXXXX")" || exit 1
SUT="$SCRIPT_DIR/../hooks/git-gate-dispatch.sh"

pass=0
fail=0

export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@test
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@test
unset CLAUDE_PROJECT_DIR

make_repo() { # make_repo <branch> -> prints repo path
  local r
  r=$(mktemp -d "${TMPDIR:-/tmp}/hooktest.XXXXXX")
  (cd "$r" && git init -q -b "$1" \
    && git config user.email test@test && git config user.name test \
    && git commit -q --allow-empty -m "chore: init")
  printf '%s\n' "$r"
}

# A bin dir with every standard tool EXCEPT jq, so we can exercise the
# jq-missing path. A bare PATH=/usr/bin:/bin does NOT work: current macOS ships
# jq in /usr/bin, so it would still be found.
make_nojq_bin() {
  local d b name
  d=$(mktemp -d "${TMPDIR:-/tmp}/nojqbin.XXXXXX")
  for b in /bin/* /usr/bin/*; do
    name=$(basename "$b")
    [ "$name" = jq ] && continue
    [ -e "$d/$name" ] || ln -s "$b" "$d/$name"
  done
  printf '%s\n' "$d"
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

feature=$(make_repo feat/topic)
main=$(make_repo main)

run_case "non-git command passes through" 0 "$feature" 'ls -la'
run_case "git status routes to no gate" 0 "$feature" 'git status'

# Meta gate is reachable and runs regardless of subcommand.
run_case "git -c injection routes to meta gate" 2 "$feature" \
  'git -c core.pager=/bin/sh status'
run_case "git diff --no-index routes to meta gate" 2 "$feature" \
  'git diff --no-index /dev/null /etc/hosts'

# Commit-gate family is reachable.
run_case "conventional commit on feature branch allowed" 0 "$feature" \
  'git commit -m "feat: add thing"'
run_case "commit on main blocked (branch gate)" 2 "$main" \
  'git commit -m "feat: add thing"'
run_case "coauthor commit blocked (coauthor gate)" 2 "$feature" \
  'git commit -m "feat: x" -m "Co-Authored-By: Claude <noreply@anthropic.com>"'
run_case "non-conventional message blocked (conventional gate)" 2 "$feature" \
  'git commit -m "added stuff"'

# Push-gate family is reachable.
run_case "push without verify marker blocked (verify gate)" 2 "$feature" \
  'git push origin feat/topic'

# SKIP_* bypasses must reach the child gates through the dispatcher.
jq -n --arg cmd 'git push origin feat/topic' '{tool_input:{command:$cmd}}' \
  | (cd "$feature" && SKIP_VERIFY_GATE=1 bash "$SUT") >/dev/null 2>&1
if [ $? -eq 0 ]; then
  echo "PASS: SKIP env reaches child gate through dispatcher (exit 0)"
  pass=$((pass + 1))
else
  echo "FAIL: SKIP env reaches child gate through dispatcher — expected exit 0"
  fail=$((fail + 1))
fi

git -C "$feature" rev-parse HEAD > "$feature/.git/verify-done-ok"
run_case "push with fresh marker allowed" 0 "$feature" \
  'git push origin feat/topic'
# Force pushes on feature branches are policy-allowed — no gate may block them.
run_case "force push to feature branch allowed" 0 "$feature" \
  'git push --force origin feat/topic'

# state-refresh context envelope reaches stdout when nothing blocks...
out=$(jq -n --arg cmd 'git push origin feat/topic' '{tool_input:{command:$cmd}}' \
  | (cd "$feature" && bash "$SUT") 2>/dev/null)
case "$out" in
  *pr-state*)
    echo "PASS: allowed push emits pr-state context on stdout"
    pass=$((pass + 1))
    ;;
  *)
    echo "FAIL: allowed push emits pr-state context on stdout — got: $out"
    fail=$((fail + 1))
    ;;
esac

# ...and is suppressed when a gate blocks (no API round-trip, no mixed stdout).
rm -f "$feature/.git/verify-done-ok"
out=$(jq -n --arg cmd 'git push origin feat/topic' '{tool_input:{command:$cmd}}' \
  | (cd "$feature" && bash "$SUT") 2>/dev/null)
case "$out" in
  *pr-state*)
    echo "FAIL: blocked push must not emit pr-state context — got: $out"
    fail=$((fail + 1))
    ;;
  *)
    echo "PASS: blocked push emits no pr-state context"
    pass=$((pass + 1))
    ;;
esac

# Payload cwd is where gates run: in worktree flows the Bash tool has cd'd
# into the checkout but the hook process has not — the payload's cwd is the
# only signal, and gates falling back to $PWD must see it.
run_pcwd_case() { # run_pcwd_case <name> <expected-exit> <invoke-dir> <payload-cwd> <command-string>
  local name="$1" expected="$2" inv="$3" pcwd="$4" command="$5" got
  jq -n --arg cmd "$command" --arg cwd "$pcwd" '{cwd:$cwd, tool_input:{command:$cmd}}' \
    | (cd "$inv" && bash "$SUT") >/dev/null 2>&1
  got=$?
  if [ "$got" = "$expected" ]; then
    echo "PASS: $name (exit $got)"
    pass=$((pass + 1))
  else
    echo "FAIL: $name — expected exit $expected, got $got"
    fail=$((fail + 1))
  fi
}

neutral=$(mktemp -d "${TMPDIR:-/tmp}/hooktest-neutral.XXXXXX")
run_pcwd_case "payload cwd resolves repo: unverified push blocked" 2 \
  "$neutral" "$feature" 'git push origin feat/topic'
git -C "$feature" rev-parse HEAD > "$feature/.git/verify-done-ok"
run_pcwd_case "payload cwd resolves repo: fresh marker allows push" 0 \
  "$neutral" "$feature" 'git push origin feat/topic'
rm -f "$feature/.git/verify-done-ok"
run_pcwd_case "vanished payload cwd falls back cleanly" 0 \
  "$neutral" "$neutral/does-not-exist" 'git status'
rm -rf "$neutral"

# Force pushes targeting the default branch must stay blocked end-to-end with
# the force gate gone — the marker is fresh, so only the branch gate blocks.
git -C "$main" update-ref refs/remotes/origin/main refs/heads/main
git -C "$main" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
git -C "$main" rev-parse HEAD > "$main/.git/verify-done-ok"
run_case "force push targeting default branch blocked (branch gate)" 2 "$main" \
  'git push --force origin main'

# Without jq the dispatcher fails CLOSED: it can't parse the command, so it
# blocks git rather than letting it run ungated.
nojq=$(make_nojq_bin)
jq -n --arg cmd 'git status' '{tool_input:{command:$cmd}}' \
  | (cd "$feature" && PATH="$nojq" bash "$SUT") >/dev/null 2>&1
if [ $? -eq 2 ]; then
  echo "PASS: missing jq blocks git (fail closed, exit 2)"
  pass=$((pass + 1))
else
  echo "FAIL: missing jq must block git — expected exit 2"
  fail=$((fail + 1))
fi

jq -n --arg cmd 'git status' '{tool_input:{command:$cmd}}' \
  | (cd "$feature" && PATH="$nojq" SKIP_GIT_GATE_NO_JQ=1 bash "$SUT") >/dev/null 2>&1
if [ $? -eq 0 ]; then
  echo "PASS: SKIP_GIT_GATE_NO_JQ bypasses the no-jq block (exit 0)"
  pass=$((pass + 1))
else
  echo "FAIL: SKIP_GIT_GATE_NO_JQ must allow — expected exit 0"
  fail=$((fail + 1))
fi
rm -rf "$nojq"

rm -rf "$feature" "$main"

echo ""
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
