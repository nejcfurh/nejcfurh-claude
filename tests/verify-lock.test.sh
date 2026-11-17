#!/usr/bin/env bash
# Regression tests for scripts/verify-lock.sh.
#
# The lock caps how many sessions run a gate (or use one fixed-port local
# database) at once. It must pass the command's status through, never let more
# holders in than it has slots, give up with 75 instead of waiting forever,
# and reclaim a slot whose holder died without releasing it.
# Run: bash verify-lock.test.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="$SCRIPT_DIR/../scripts/verify-lock.sh"

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

work=$(mktemp -d "${TMPDIR:-/tmp}/verifylock.XXXXXX") || exit 1
export VERIFY_LOCK_DIR="$work/locks"
holders=()
cleanup() {
  if [ ${#holders[@]} -gt 0 ]; then
    kill "${holders[@]}" 2>/dev/null
    wait "${holders[@]}" 2>/dev/null
  fi
  rm -rf "$work"
}
trap cleanup EXIT

# Occupy slot <n> of <name> with a process that stays alive.
hold() {
  sleep 60 &
  holders+=("$!")
  mkdir -p "$VERIFY_LOCK_DIR/$1/slot-$2"
  echo "$!" >"$VERIFY_LOCK_DIR/$1/slot-$2/pid"
}

passes_status() {
  bash "$SUT" st -- bash -c 'exit 3'
  [ $? -eq 3 ]
}
check "the command's exit status passes through" passes_status

releases_slot() {
  bash "$SUT" rel -- true && [ -z "$(ls -A "$VERIFY_LOCK_DIR/rel")" ]
}
check "the slot is released after the command" releases_slot

releases_on_failure() {
  bash "$SUT" relf -- false
  [ -z "$(ls -A "$VERIFY_LOCK_DIR/relf")" ]
}
check "the slot is released when the command fails" releases_on_failure

busy_gives_up() {
  hold busy 1
  local start=$SECONDS
  bash "$SUT" --wait 0 busy -- touch "$work/ran" 2>"$work/busy.err"
  local rc=$?
  [ "$rc" -eq 75 ] && [ ! -e "$work/ran" ] && [ $((SECONDS - start)) -lt 5 ] \
    && grep -q 'stayed busy' "$work/busy.err"
}
check "a full lock exits 75 without running the command" busy_gives_up

second_slot_free() {
  hold two 1
  bash "$SUT" --slots 2 --wait 0 two -- true
}
check "a second slot admits a second holder" second_slot_free

reclaims_dead() {
  mkdir -p "$VERIFY_LOCK_DIR/dead/slot-1"
  bash -c 'exit 0' &
  local pid=$!
  wait "$pid"
  echo "$pid" >"$VERIFY_LOCK_DIR/dead/slot-1/pid"
  bash "$SUT" --wait 0 dead -- true
}
check "a slot whose holder exited is reclaimed" reclaims_dead

reclaims_old() {
  hold old 1
  touch -t 202001010000 "$VERIFY_LOCK_DIR/old/slot-1"
  bash "$SUT" --wait 0 old -- true
}
check "a slot older than any gate run is reclaimed" reclaims_old

waits_then_runs() {
  mkdir -p "$VERIFY_LOCK_DIR/wait"
  bash "$SUT" wait -- sleep 2 &
  local first=$!
  sleep 0.5
  bash "$SUT" --wait 20 wait -- true 2>"$work/wait.err"
  local rc=$?
  wait "$first"
  [ "$rc" -eq 0 ] && grep -q 'got a .wait. slot' "$work/wait.err"
}
check "a waiter runs once the holder finishes" waits_then_runs

never_overlaps() {
  local _ pids=()
  rm -f "$work/overlap"
  for _ in 1 2 3 4; do
    bash "$SUT" --wait 30 one -- bash -c \
      "mkdir '$work/inside' 2>/dev/null || touch '$work/overlap'; sleep 0.3; rmdir '$work/inside'" &
    pids+=("$!")
  done
  # Only these four: a bare `wait` also waits out the `sleep 60` holders
  # that earlier cases started, a minute on every run.
  wait "${pids[@]}"
  [ ! -e "$work/overlap" ]
}
check "one slot never admits two holders at once" never_overlaps

bad_usage() {
  bash "$SUT" -- true 2>/dev/null
  [ $? -eq 2 ] || return 1
  bash "$SUT" x 2>/dev/null
  [ $? -eq 2 ] || return 1
  bash "$SUT" --slots 0 x -- true 2>/dev/null
  [ $? -eq 2 ] || return 1
  bash "$SUT" ../escape -- true 2>/dev/null
  [ $? -eq 2 ]
}
check "bad usage exits 2" bad_usage

echo ""
echo "verify-lock: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
