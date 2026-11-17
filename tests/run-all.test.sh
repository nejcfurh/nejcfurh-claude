#!/usr/bin/env bash
# Regression tests for tests/run-all.sh.
#
# The runner caps how many suites run at once ($RUN_ALL_JOBS, default 8):
# starting all of them together cost more CPU and finished no sooner. The cap
# must hold, suites must still overlap under it, and a failing suite must
# still fail the run and be named.
# Run: bash run-all.test.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER="$SCRIPT_DIR/run-all.sh"

pass=0
fail=0

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

work=$(mktemp -d "${TMPDIR:-/tmp}/runall.XXXXXX") || exit 1
trap 'rm -rf "$work"' EXIT

# make_suites <dir> <count>: a copy of the runner beside <count> fake suites.
# Each suite marks itself running, records how many are running, then waits
# long enough for the runner to start every suite it is allowed to.
make_suites() {
  local dir="$1" n="$2" i
  mkdir -p "$dir/running"
  cp "$RUNNER" "$dir/run-all.sh"
  for i in $(seq -w 1 "$n"); do
    cat >"$dir/s$i.test.sh" <<EOF
touch "$dir/running/\$\$"
ls "$dir/running" | wc -l | tr -d ' ' >>"$dir/counts"
sleep 0.5
rm -f "$dir/running/\$\$"
echo "suite s$i done"
EOF
  done
}

peak() { sort -n "$1/counts" | tail -n1; }

caps_concurrency() {
  local d="$work/cap"
  make_suites "$d" 6
  RUN_ALL_JOBS=2 bash "$d/run-all.sh" >"$d/out" 2>&1 || return 1
  [ "$(wc -l <"$d/counts" | tr -d ' ')" -eq 6 ] && [ "$(peak "$d")" -le 2 ]
}
check "RUN_ALL_JOBS=2 never runs more than two suites at once" caps_concurrency

still_parallel() {
  [ "$(peak "$work/cap")" -eq 2 ]
}
check "suites still overlap under the cap" still_parallel

default_cap_is_eight() {
  local d="$work/default"
  make_suites "$d" 10
  (unset RUN_ALL_JOBS; bash "$d/run-all.sh") >"$d/out" 2>&1 || return 1
  [ "$(peak "$d")" -le 8 ] && [ "$(peak "$d")" -gt 1 ]
}
check "with RUN_ALL_JOBS unset, at most eight suites run at once" default_cap_is_eight

zero_means_all() {
  local d="$work/zero"
  make_suites "$d" 6
  RUN_ALL_JOBS=0 bash "$d/run-all.sh" >"$d/out" 2>&1 || return 1
  [ "$(peak "$d")" -gt 2 ]
}
check "RUN_ALL_JOBS=0 starts every suite at once" zero_means_all

failure_is_reported() {
  local d="$work/failing"
  make_suites "$d" 3
  printf 'echo broken\nexit 1\n' >"$d/s02.test.sh"
  RUN_ALL_JOBS=2 bash "$d/run-all.sh" >"$d/out" 2>&1
  [ $? -eq 1 ] && grep -q '^Some suites FAILED:' "$d/out" && grep -q '^  - s02.test.sh$' "$d/out" \
    && ! grep -q '^  - s01.test.sh$' "$d/out" && ! grep -q '^  - s03.test.sh$' "$d/out"
}
check "a failing suite fails the run and is the only one named" failure_is_reported

output_in_order() {
  # Suites finish in any order; their output prints in name order.
  grep '^=== ' "$work/cap/out" | tr '\n' ' ' \
    | grep -q '^=== s1.test.sh === s2.test.sh === s3.test.sh === s4.test.sh === s5.test.sh === s6.test.sh $'
}
check "suite output prints in name order" output_in_order

rejects_bad_value() {
  local d="$work/bad"
  make_suites "$d" 1
  RUN_ALL_JOBS=four bash "$d/run-all.sh" >"$d/out" 2>&1
  [ $? -eq 1 ] && grep -q 'RUN_ALL_JOBS must be a whole number' "$d/out" && [ ! -s "$d/counts" ]
}
check "a non-numeric RUN_ALL_JOBS is refused before any suite runs" rejects_bad_value

echo ""
echo "run-all: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
