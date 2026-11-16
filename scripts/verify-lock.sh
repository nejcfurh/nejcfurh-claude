#!/usr/bin/env bash
# Runs a command while holding one of N machine-wide slots named <name>, so
# parallel sessions cannot all run their gates (or all hit one fixed-port
# local database) at the same moment. Waits up to --wait seconds for a slot,
# then gives up with exit 75 instead of queueing past the caller's timeout.
#
# Usage: verify-lock.sh [--slots N] [--wait SECONDS] <name> -- <command…>
#   --slots  how many holders may run at once (default 1)
#   --wait   how long to wait for a free slot (default 240)
# Slots live under $VERIFY_LOCK_DIR (default /tmp/claude/verify-locks): a
# path both sandboxed and unsandboxed shells can write, so every session sees
# the same slots. A slot whose holder has exited is reclaimed.
# Exit: the command's own status; 75 no slot within --wait; 2 bad usage.
set -u

slots=1
wait_secs=240
while [ $# -gt 0 ]; do
  case "$1" in
    --slots) slots="${2:-}"; shift 2 ;;
    --wait) wait_secs="${2:-}"; shift 2 ;;
    --) shift; break ;;
    -*) echo "verify-lock: unknown option: $1" >&2; exit 2 ;;
    *) [ -z "${name:-}" ] || { echo "verify-lock: one name only" >&2; exit 2; }
       name="$1"; shift ;;
  esac
done
case "${name:-}" in
  "" | */* | .*) echo "verify-lock: usage: verify-lock.sh [--slots N] [--wait S] <name> -- <command…>" >&2; exit 2 ;;
esac
case "$slots$wait_secs" in *[!0-9]*) echo "verify-lock: --slots and --wait take whole numbers" >&2; exit 2 ;; esac
[ "$slots" -ge 1 ] || { echo "verify-lock: --slots must be at least 1" >&2; exit 2; }
[ $# -gt 0 ] || { echo "verify-lock: no command after --" >&2; exit 2; }

dir="${VERIFY_LOCK_DIR:-/tmp/claude/verify-locks}/$name"
mkdir -p "$dir" || { echo "verify-lock: cannot create $dir" >&2; exit 2; }

# A sandboxed shell may not signal another session's process: kill -0 then
# fails with "Operation not permitted", and that holder is alive. Only "No
# such process" means the slot is free to reclaim — or a slot older than any
# gate run, whose pid may since have been reused by an unrelated process.
holder_dead() {
  local pid
  [ -n "$(find "$1" -maxdepth 0 -mmin +"${VERIFY_LOCK_MAX_AGE_MINUTES:-60}" 2>/dev/null)" ] && return 0
  pid=$(cat "$1/pid" 2>/dev/null) || return 1
  [ -n "$pid" ] || return 1
  kill -0 "$pid" 2>&1 | grep -q 'No such process'
}

held=""
try_take() {
  local i=1 s
  while [ "$i" -le "$slots" ]; do
    s="$dir/slot-$i"
    if mkdir "$s" 2>/dev/null; then
      echo "$$" >"$s/pid"
      held="$s"
      return 0
    fi
    # A slot just created by mkdir has no pid file for an instant: only a
    # recorded pid that no longer exists frees it.
    # Rename before deleting: mv is atomic, so of two waiters reclaiming the
    # same dead slot only one succeeds.
    if holder_dead "$s" && mv "$s" "$s.stale.$$" 2>/dev/null; then
      rm -rf "$s.stale.$$"
      continue
    fi
    i=$((i + 1))
  done
  return 1
}

release() { [ -n "$held" ] && rm -rf "$held"; held=""; }
trap release EXIT
trap 'release; exit 130' INT
trap 'release; exit 143' TERM

start=$SECONDS
announced=""
until try_take; do
  if [ $((SECONDS - start)) -ge "$wait_secs" ]; then
    echo "verify-lock: '$name' stayed busy for ${wait_secs}s ($slots slot(s), all held by other sessions) — retry once one finishes" >&2
    exit 75
  fi
  if [ -z "$announced" ]; then
    echo "verify-lock: waiting for a '$name' slot ($slots in use by other sessions)…" >&2
    announced=1
  fi
  sleep 2
done
[ -n "$announced" ] && echo "verify-lock: got a '$name' slot after $((SECONDS - start))s" >&2

"$@"
