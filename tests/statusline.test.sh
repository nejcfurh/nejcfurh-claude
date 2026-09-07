#!/usr/bin/env bash
# Regression tests for scripts/statusline.sh — the context-usage segment.
#
# The load-bearing case here is ABSENCE. context_window.used_percentage is
# input-only and is null before the first API call and again after /compact, so
# the segment has to disappear rather than render 0% and tell the reader the
# window is empty when it is merely unmeasured. A non-numeric value must take
# the same path: it is the only thing standing between a malformed payload and
# an arithmetic error in the colour comparison.
#
# The dir is a temp non-repo so the git segment stays out of the way, and every
# assertion matches a substring rather than the whole line — the greeting
# segment depends on whether ~/.claude/hooks exists on the machine running this.
# Run: bash statusline.test.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="$SCRIPT_DIR/../scripts/statusline.sh"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/statusline-test.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT
cd "$TMP" || exit 1

pass=0
fail=0

RED=$'\033[31m'
YELLOW=$'\033[33m'
DIM=$'\033[2m'

# render <context_window-json-or-empty> — the payload the statusline receives.
render() {
  local cw="$1" payload
  if [ -z "$cw" ]; then
    payload=$(printf '{"workspace":{"current_dir":"%s"},"model":{"display_name":"M"}}' "$TMP")
  else
    payload=$(printf '{"workspace":{"current_dir":"%s"},"model":{"display_name":"M"},"context_window":%s}' "$TMP" "$cw")
  fi
  printf '%s' "$payload" | bash "$SUT" 2>/dev/null
}

# shows <name> <context_window-json> <expected substring>
shows() {
  local name="$1" cw="$2" want="$3" out
  out=$(render "$cw")
  case "$out" in
    *"$want"*) echo "PASS: $name"; pass=$((pass + 1)) ;;
    *) echo "FAIL: $name (want [$want] in [$out])"; fail=$((fail + 1)) ;;
  esac
}

# omits <name> <context_window-json-or-empty> — expects no ctx segment at all
omits() {
  local name="$1" cw="$2" out
  out=$(render "$cw")
  case "$out" in
    *"context used"*) echo "FAIL: omits — $name (unexpected context segment: [$out])"; fail=$((fail + 1)) ;;
    *) echo "PASS: omits — $name"; pass=$((pass + 1)) ;;
  esac
}

# omits_substring <name> <context_window-json> <substring that must NOT appear>
omits_substring() {
  local name="$1" cw="$2" unwanted="$3" out
  out=$(render "$cw")
  case "$out" in
    *"$unwanted"*) echo "FAIL: $name (found [$unwanted] in [$out])"; fail=$((fail + 1)) ;;
    *) echo "PASS: $name"; pass=$((pass + 1)) ;;
  esac
}

# --- renders: a measured percentage -------------------------------------------
shows "percentage" '{"used_percentage":42,"context_window_size":1000000}' '42% of context used'
shows "floors a float rather than rounding" '{"used_percentage":42.9,"context_window_size":1000000}' '42% of context used'
shows "renders without a window size in the payload" '{"used_percentage":30}' '30% of context used'
shows "window size is ignored, not rendered" '{"used_percentage":42,"context_window_size":200000}' '42% of context used'
omits_substring "no window size leaks into the segment" '{"used_percentage":42,"context_window_size":200000}' '200k'

# --- colour tracks context-nudge.sh's own 50/75/90 tiers ---------------------
shows "dim below 50" '{"used_percentage":49,"context_window_size":1000000}' "${DIM}49%"
shows "yellow from 50" '{"used_percentage":50,"context_window_size":1000000}' "${YELLOW}50%"
shows "still yellow at 89" '{"used_percentage":89,"context_window_size":1000000}' "${YELLOW}89%"
shows "red from 90" '{"used_percentage":90,"context_window_size":1000000}' "${RED}90%"

# --- omits: unmeasured is not zero -------------------------------------------
omits "null percentage — before the first API call" '{"used_percentage":null,"context_window_size":1000000}'
omits "percentage absent but size present" '{"context_window_size":1000000}'
omits "no context_window object at all" ''
omits "non-numeric percentage" '{"used_percentage":"lots","context_window_size":1000000}'
omits "negative percentage" '{"used_percentage":-5,"context_window_size":1000000}'

# --- the rest of the line survives -------------------------------------------
shows "model segment still rendered alongside" '{"used_percentage":42,"context_window_size":1000000}' 'M'
shows "model segment still rendered without a context window" '' 'M'

# --- a malformed size is simply not read any more -----------------------------
shows "non-numeric size is harmless" '{"used_percentage":42,"context_window_size":"big"}' '42% of context used'

echo ""
echo "passed: $pass, failed: $fail"
[ "$fail" -eq 0 ]
