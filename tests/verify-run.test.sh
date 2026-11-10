#!/usr/bin/env bash
# Regression tests for scripts/verify-run.sh.
#
# The runner turns /verify-done's cached plan into commands: the scoped form of
# each test line in scoped mode, the full form otherwise, every check and test
# line at once. It must refuse a stale or old-format plan rather than run it,
# and it must not report a pass for a runner that found nothing to test.
# Run: bash verify-run.test.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# A failed mktemp must never leak this suite's git commands into the real repo.
cd "$(mktemp -d "${TMPDIR:-/tmp}/hooktest-cwd.XXXXXX")" || exit 1
SUT="$SCRIPT_DIR/../scripts/verify-run.sh"
FP="$SCRIPT_DIR/../scripts/verify-plan-fingerprint.sh"

pass=0
fail=0

export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@test
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@test
unset VERIFY_DONE_FULL

check() { # check <name> <command…> — passes when the command exits 0
  local name="$1"
  shift
  if "$@"; then
    echo "PASS: $name"
    pass=$((pass + 1))
  else
    echo "FAIL: $name"
    fail=$((fail + 1))
  fi
}

repo=$(mktemp -d "${TMPDIR:-/tmp}/hooktest.XXXXXX")
out=$(mktemp -d "${TMPDIR:-/tmp}/hooktest.XXXXXX")
(
  cd "$repo" && git init -q -b main \
    && mkdir -p hooks tests \
    && printf 'echo foo\n' > hooks/foo.sh \
    && for n in foo a b c; do printf 'true\n' > "tests/$n.test.sh"; done \
    && git add -A && git commit -q -m "chore: init" \
    && git checkout -q -b work/topic \
    && echo "# edit" >> hooks/foo.sh
)
plan="$repo/.git/verify-done-plan"

write_plan() { # write_plan <line…> — fingerprint first, then the given lines
  {
    (cd "$repo" && bash "$FP")
    printf '%s\n' "$@"
  } > "$plan"
}

run() { (cd "$repo" && bash "$SUT" --base main "$@" 2>&1); }

T=$'\t'

scoped_substitutes() {
  rm -f "$out"/*
  write_plan "test${T}echo full > $out/which${T}printf '%s\\n' {tests} > $out/args"
  run >/dev/null && [ "$(cat "$out/args")" = "tests/foo.test.sh" ] && [ ! -f "$out/which" ]
}
check "scoped mode runs the scoped form with the selected tests" scoped_substitutes

full_uses_full_form() {
  rm -f "$out"/*
  write_plan "test${T}echo full > $out/which${T}echo scoped > $out/which"
  run --full >/dev/null && [ "$(cat "$out/which")" = "full" ]
}
check "full mode runs the full form" full_uses_full_form

reports_mode() {
  write_plan "test${T}true${T}true {tests}"
  run | tail -n1 | grep -q 'result=PASS mode=scoped selected=1 total=4'
}
check "last line reports result, mode and selection" reports_mode

no_scoped_form_runs_full() {
  rm -f "$out"/*
  write_plan "test${T}echo full > $out/which"
  run >/dev/null && [ "$(cat "$out/which")" = "full" ]
}
check "a test line with no scoped form runs in full" no_scoped_form_runs_full

empty_selection_skips() {
  rm -f "$out"/*
  write_plan "test${T}echo full > $out/which${T}echo scoped {files} > $out/which"
  run | grep -q 'SKIP test (scoped)' && [ ! -f "$out/which" ]
}
check "a scoped line with nothing to run is skipped, not run in full" empty_selection_skips

failing_check_fails() {
  write_plan "check${T}echo lint-broke; exit 1" "test${T}true${T}true {tests}"
  local o
  o=$(run)
  [ $? -eq 1 ] && printf '%s\n' "$o" | grep -q 'lint-broke' \
    && printf '%s\n' "$o" | tail -n1 | grep -q 'result=FAIL'
}
check "a failing check fails the run and prints its output" failing_check_fails

no_tests_found_escalates() {
  rm -f "$out"/*
  write_plan "test${T}echo full > $out/which${T}echo 'No test files found'; exit 1"
  local o
  o=$(run)
  [ $? -eq 0 ] && [ "$(cat "$out/which")" = "full" ] \
    && printf '%s\n' "$o" | grep -q 'ESCALATE'
}
check "runner finding no related tests escalates to its full suite" no_tests_found_escalates

setup_runs_first() {
  rm -f "$out"/*
  write_plan "check${T}test -f $out/installed" "setup${T}touch $out/installed"
  run >/dev/null
}
check "setup lines run before every check" setup_runs_first

failing_setup_stops() {
  rm -f "$out"/*
  write_plan "setup${T}exit 1" "check${T}touch $out/ran"
  ! run >/dev/null && [ ! -f "$out/ran" ]
}
check "a failing setup stops before any check" failing_setup_stops

runs_concurrently() {
  write_plan "check${T}sleep 2" "check${T}sleep 2" "test${T}sleep 2"
  local start=$SECONDS
  run >/dev/null && [ $((SECONDS - start)) -lt 5 ]
}
check "check and test lines run concurrently" runs_concurrently

stale_refused() {
  printf 'not-the-fingerprint\ncheck%strue\n' "$T" > "$plan"
  run >/dev/null
  [ $? -eq 3 ]
}
check "stale plan is refused with exit 3" stale_refused

v1_refused() {
  write_plan "bash tests/run-all.sh"
  run >/dev/null
  [ $? -eq 3 ]
}
check "untagged v1 plan is refused with exit 3" v1_refused

missing_refused() {
  rm -f "$plan"
  run >/dev/null
  [ $? -eq 3 ]
}
check "missing plan is refused with exit 3" missing_refused

rm -rf "$repo" "$out"

echo ""
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
