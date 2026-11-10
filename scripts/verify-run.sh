#!/usr/bin/env bash
# Runs /verify-done's cached check plan: setup lines first, one at a time,
# then every check and test line concurrently. Test lines run in the mode
# verify-scope.sh picks — the related tests only, or the full suite.
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
# Exit: 0 every line passed, 1 a line failed, 3 plan missing, stale or not v2
# (rediscover and rewrite it). The last line of output is
# `verify-run: result=PASS|FAIL mode=scoped|full …` — pass that mode to
# record-verify-pass.sh.
set -u

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

stale() { echo "verify-run: $1 — rediscover the plan and rewrite $plan" >&2; exit 3; }
[ -f "$plan" ] || stale "no plan cache"
[ "$(head -n1 "$plan")" = "$("$here/verify-plan-fingerprint.sh")" ] || stale "plan cache is stale"
if tail -n +2 "$plan" | grep -v '^$' | grep -qvE $'^(setup|check|test)\t'; then
  stale "plan cache is not in the tagged v2 format"
fi

scope=$("$here/verify-scope.sh" ${scope_args[@]+"${scope_args[@]}"}) || {
  echo "verify-run: verify-scope.sh failed" >&2
  exit 2
}
mode=$(printf '%s\n' "$scope" | sed -n 's/^mode=//p')
reason=$(printf '%s\n' "$scope" | sed -n 's/^reason=//p')
counts=$(printf '%s\n' "$scope" | sed -n 's/^\(selected=.*\)/\1/p')
tests_q=$(printf '%s\n' "$scope" | sed -n 's/^test=//p' | while IFS= read -r t; do printf '%q ' "$t"; done)
files_q=$(printf '%s\n' "$scope" | sed -n 's/^native=//p' | while IFS= read -r t; do printf '%q ' "$t"; done)

echo "verify-run: mode=$mode ($reason)"
[ -n "$counts" ] && echo "verify-run: $counts"

log_dir=$(mktemp -d "${TMPDIR:-/tmp}/verify-run.XXXXXX") || exit 2
trap 'rm -rf "$log_dir"' EXIT

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
      case "$run" in *"{tests}"*) [ -n "$tests_q" ] || skip=1; run="${run//\{tests\}/$tests_q}" ;; esac
      case "$run" in *"{files}"*) [ -n "$files_q" ] || skip=1; run="${run//\{files\}/$files_q}" ;; esac
      if [ -n "$skip" ]; then
        echo "=== SKIP test (scoped): no related tests for: $cmd"
        continue
      fi
      cmds+=("$run"); labels+=("test (scoped)"); fulls+=("$cmd") ;;
  esac
done < <(tail -n +2 "$plan")

pids=()
i=0
while [ "$i" -lt "${#cmds[@]}" ]; do
  (
    start=$SECONDS
    bash -c "${cmds[$i]}" >"$log_dir/$i.out" 2>&1
    rc=$?
    echo "$((SECONDS - start))" >"$log_dir/$i.secs"
    exit "$rc"
  ) &
  pids+=("$!")
  i=$((i + 1))
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
      if bash -c "${cmds[$i]}" >"$log_dir/$i.out" 2>&1; then status=PASS; fi
      echo "$((SECONDS - start))" >"$log_dir/$i.secs"
    fi
  fi
  [ "$status" = "FAIL" ] && failed=1
  echo "=== $status ${labels[$i]} ($(cat "$log_dir/$i.secs" 2>/dev/null)s): ${cmds[$i]}"
  if [ "$status" = "FAIL" ]; then
    cat "$log_dir/$i.out"
  else
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
