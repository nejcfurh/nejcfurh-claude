#!/usr/bin/env bash
# Runs /verify-done's cached check plan: setup lines first, one at a time,
# then the check and test lines, $VERIFY_DONE_LINES at a time (default 2,
# check lines first). Test lines run in the mode verify-scope.sh picks — the
# related tests only, or the full suite.
#
# Plan cache (.git/verify-done-plan), tab-separated after the fingerprint line:
#   <fingerprint from verify-plan-fingerprint.sh>
#   setup<TAB><command>                      e.g. an install step
#   check<TAB><command>                      lint, typecheck, build, …
#   test<TAB><full command>[<TAB><scoped command>]
# A scoped command names its inputs with {tests} (selected test files) and/or
# {files} (changed JS/TS files, for `vitest related` / `jest
# --findRelatedTests`). Commands run from the repository root.
#
# Usage: verify-run.sh [--full] [--base <ref>]
# Every plan line sees the resolved PR base as $VERIFY_BASE, and the path of
# a file listing every changed file as $VERIFY_CHANGED_FILES — committed,
# staged, unstaged and untracked. A guarded line greps that file, so it sees
# the same changes before a commit as after it.
# Exit: 0 every line passed, 1 a line failed, 3 plan missing, stale or not v2
# (rediscover and rewrite it), 75 too many gates already running (re-run
# later). A missing or stale plan is first replaced by a sibling worktree's
# plan whose fingerprint matches. The last line of output is
# `verify-run: result=PASS|FAIL|BUSY mode=scoped|full …` — pass that mode to
# record-verify-pass.sh.
#
# At most $VERIFY_DONE_SLOTS gates (default 2) run on this machine at once;
# another waits up to $VERIFY_DONE_WAIT seconds (default 240) for a slot.
# Parallel sessions each starting a full test run otherwise ask for several
# times the machine's cores. VERIFY_DONE_SLOTS=0 turns the cap off.
set -u

orig_args=("$@")
scope_args=()
while [ $# -gt 0 ]; do
  case "$1" in
    --full) scope_args+=(--full); shift ;;
    --base) scope_args+=(--base "${2:-}"); shift 2 ;;
    *) echo "verify-run: unknown argument: $1" >&2; exit 2 ;;
  esac
done

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo=$(git rev-parse --show-toplevel 2>/dev/null) || {
  echo "verify-run: not inside a git repository" >&2
  exit 2
}
cd "$repo" || exit 2
plan="$(git rev-parse --absolute-git-dir)/verify-done-plan"

fingerprint=$("$here/verify-plan-fingerprint.sh")
stale() { echo "verify-run: $1 — rediscover the plan and rewrite $plan" >&2; exit 3; }
is_v2() { ! tail -n +2 "$1" | grep -v '^$' | grep -qvE $'^(setup|check|test)\t'; }
usable() { [ -f "$1" ] && [ "$(head -n1 "$1")" = "$fingerprint" ] && is_v2 "$1"; }

# A fresh worktree has no plan of its own. A sibling checkout's plan with the
# same fingerprint was discovered from identical CI and manifest inputs.
if ! usable "$plan"; then
  common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
  if [ -n "$common" ]; then
    for candidate in "$common/verify-done-plan" "$common"/worktrees/*/verify-done-plan; do
      [ "$candidate" != "$plan" ] && usable "$candidate" || continue
      cp "$candidate" "$plan" && echo "verify-run: reused the plan from $candidate"
      break
    done
  fi
fi

[ -f "$plan" ] || stale "no plan cache"
[ "$(head -n1 "$plan")" = "$fingerprint" ] || stale "plan cache is stale"
is_v2 "$plan" || stale "plan cache is not in the tagged v2 format"

# At most $VERIFY_DONE_LINES check/test lines run at once (default 2, 0 = all).
max_lines="${VERIFY_DONE_LINES:-2}"
case "$max_lines" in
  "" | *[!0-9]*) echo "verify-run: VERIFY_DONE_LINES must be a whole number, got: $max_lines" >&2; exit 2 ;;
esac
# VERIFY_DONE_QOS=background runs check/test lines at background QoS
# (`taskpolicy -b`): macOS keeps them on the efficiency cores. Measured on one
# app's gate it took 4-5x as long and failed two timing-sensitive tests.
# Where taskpolicy is missing, lines run unchanged.
qos=()
case "${VERIFY_DONE_QOS:-normal}" in
  normal) ;;
  background) command -v taskpolicy >/dev/null 2>&1 && qos=(taskpolicy -b) ;;
  *) echo "verify-run: VERIFY_DONE_QOS must be normal or background, got: $VERIFY_DONE_QOS" >&2; exit 2 ;;
esac

# Take a gate slot only once the plan is known good, so a stale plan is
# reported at once instead of after a wait. The run under the slot repeats
# the checks above, which are cheap.
slots="${VERIFY_DONE_SLOTS:-2}"
if [ -z "${VERIFY_RUN_LOCKED:-}" ] && [ "$slots" != 0 ]; then
  VERIFY_RUN_LOCKED=1 "$here/verify-lock.sh" --slots "$slots" --wait "${VERIFY_DONE_WAIT:-240}" \
    gate -- bash "$here/verify-run.sh" ${orig_args[@]+"${orig_args[@]}"}
  rc=$?
  if [ "$rc" -eq 75 ]; then
    echo "verify-run: result=BUSY ($slots gates already running on this machine; re-run when one finishes)"
  fi
  exit "$rc"
fi

scope=$("$here/verify-scope.sh" ${scope_args[@]+"${scope_args[@]}"}) || {
  echo "verify-run: verify-scope.sh failed" >&2
  exit 2
}
mode=$(printf '%s\n' "$scope" | sed -n 's/^mode=//p')
reason=$(printf '%s\n' "$scope" | sed -n 's/^reason=//p')
counts=$(printf '%s\n' "$scope" | sed -n 's/^\(selected=.*\)/\1/p')
verify_base=$(printf '%s\n' "$scope" | sed -n 's/^base=//p' | tail -n1)
if [ -n "$verify_base" ] && [ "$verify_base" != unknown ]; then
  export VERIFY_BASE="$verify_base"
fi
tests_q=$(printf '%s\n' "$scope" | sed -n 's/^test=//p' | while IFS= read -r t; do printf '%q ' "$t"; done)
files_q=$(printf '%s\n' "$scope" | sed -n 's/^native=//p' | while IFS= read -r t; do printf '%q ' "$t"; done)

echo "verify-run: mode=$mode ($reason)"

log_dir=$(mktemp -d "${TMPDIR:-/tmp}/verify-run.XXXXXX") || exit 2
trap 'rm -rf "$log_dir"' EXIT

# Every changed file, one per line: committed since the merge-base, staged,
# unstaged and untracked, so a guarded line runs the same before a commit as
# after it. Without a base to diff against the list names every file, and
# every guard runs instead of skipping.
export VERIFY_CHANGED_FILES="$log_dir/changed-files"
if [ -n "${VERIFY_BASE:-}" ] && git merge-base "$VERIFY_BASE" HEAD >/dev/null 2>&1; then
  printf '%s\n' "$scope" | sed -n 's/^file=//p' >"$VERIFY_CHANGED_FILES"
else
  echo "verify-run: no merge-base with the PR base; guarded lines see every file as changed"
  {
    git -c core.quotePath=false ls-files
    git -c core.quotePath=false ls-files --others --exclude-standard
  } 2>/dev/null | sort -u >"$VERIFY_CHANGED_FILES"
fi

# Setup lines may install into the tree every later line reads: serial, first.
while IFS=$'\t' read -r kind cmd _; do
  [ "$kind" = "setup" ] || continue
  echo "=== setup: $cmd"
  if ! bash -c "$cmd"; then
    echo "verify-run: result=FAIL mode=$mode (setup failed: $cmd)"
    exit 1
  fi
done < <(tail -n +2 "$plan")

# Expand each check/test line into the command this mode runs.
cmds=()
labels=()
fulls=()
uses_tests=""
while IFS=$'\t' read -r kind cmd scoped; do
  case "$kind" in
    check) cmds+=("$cmd"); labels+=("check"); fulls+=("") ;;
    test)
      if [ "$mode" = "full" ] || [ -z "$scoped" ]; then
        cmds+=("$cmd"); labels+=("test (full)"); fulls+=("")
        continue
      fi
      run="$scoped"
      skip=""
      case "$run" in *"{tests}"*) uses_tests=1; [ -n "$tests_q" ] || skip=1; run="${run//\{tests\}/$tests_q}" ;; esac
      case "$run" in *"{files}"*) [ -n "$files_q" ] || skip=1; run="${run//\{files\}/$files_q}" ;; esac
      if [ -n "$skip" ]; then
        echo "=== SKIP test (scoped): no related tests for: $cmd"
        continue
      fi
      cmds+=("$run"); labels+=("test (scoped)"); fulls+=("$cmd") ;;
  esac
done < <(tail -n +2 "$plan")

# The counts cover name-mapped suites ({tests}) only. A runner given {files}
# picks its own tests, so 0/0 there would read as "nothing was tested".
if [ "$mode" = "scoped" ] && [ -z "$uses_tests" ]; then
  counts=""
  echo "verify-run: tests selected by each runner from the changed files; see its summary line"
elif [ -n "$counts" ]; then
  echo "verify-run: $counts"
fi

[ "$max_lines" -eq 0 ] && max_lines=${#cmds[@]}
[ "$max_lines" -eq 0 ] && max_lines=1
pids=()
launch() { # launch <index> — start one line in the background, capped by $max_lines
  while [ "$(jobs -pr | wc -l)" -ge "$max_lines" ]; do sleep 0.2; done
  (
    start=$SECONDS
    ${qos[@]+"${qos[@]}"} bash -c "${cmds[$1]}" >"$log_dir/$1.out" 2>&1
    rc=$?
    echo "$((SECONDS - start))" >"$log_dir/$1.secs"
    exit "$rc"
  ) &
  pids[$1]=$!
}
# Check lines start first: they are the quick ones, and a lint failure then
# shows before the test run finishes. Output still prints in plan order.
for pass_kind in check test; do
  i=0
  while [ "$i" -lt "${#cmds[@]}" ]; do
    case "${labels[$i]}" in "$pass_kind"*) launch "$i" ;; esac
    i=$((i + 1))
  done
done

failed=0
i=0
while [ "$i" -lt "${#cmds[@]}" ]; do
  if wait "${pids[$i]}"; then
    status=PASS
  else
    status=FAIL
    # A runner that found no related test for a changed code file has not
    # tested it: run that runner's full suite instead of calling it a pass.
    if [ -n "${fulls[$i]}" ] && grep -qE 'No test files found|No tests found' "$log_dir/$i.out"; then
      echo "=== ESCALATE ${labels[$i]}: runner found no related tests — running the full suite"
      labels[i]="test (full, escalated)"
      cmds[i]="${fulls[$i]}"
      start=$SECONDS
      if ${qos[@]+"${qos[@]}"} bash -c "${cmds[$i]}" >"$log_dir/$i.out" 2>&1; then status=PASS; fi
      echo "$((SECONDS - start))" >"$log_dir/$i.secs"
    fi
  fi
  [ "$status" = "FAIL" ] && failed=1
  echo "=== $status ${labels[$i]} ($(cat "$log_dir/$i.secs" 2>/dev/null)s): ${cmds[$i]}"
  if [ "$status" = "FAIL" ]; then
    cat "$log_dir/$i.out"
  else
    # The runner's count line, when the tail would cut it off: a pass that
    # cannot show how many tests ran is not evidence that any did.
    case "${labels[$i]}" in
      test*)
        total_lines=$(wc -l <"$log_dir/$i.out")
        head -n "$((total_lines > 3 ? total_lines - 3 : 0))" "$log_dir/$i.out" \
          | grep -E '^[[:space:]]*(Test Files|Test Suites|Tests?):?[[:space:]]+[0-9]' || true
        ;;
    esac
    tail -n 3 "$log_dir/$i.out"
  fi
  i=$((i + 1))
done

if [ "$failed" -eq 0 ]; then
  echo "verify-run: result=PASS mode=$mode${counts:+ $counts}"
else
  echo "verify-run: result=FAIL mode=$mode${counts:+ $counts}"
fi
exit "$failed"
