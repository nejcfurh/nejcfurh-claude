#!/usr/bin/env bash
# PreToolUse (Bash, git commit|push): block a commit or push that follows a
# check command (lint, test, typecheck, build, format) through a separator that
# ignores the check's exit status.
#
# `npm run lint; git commit` commits whether lint passed or not. A `;`, a
# newline, `||`, a background `&` and a plain pipe all run the next command
# regardless of the check's status, so the run reads like a gated commit while
# the failure sits in the scrollback after the commit has already landed. Only
# `&&` from the first check to the git command makes the check a gate.
#
# Allowed on purpose: `set -e` earlier in the command makes `;` and newlines
# safe, `pipefail` makes a pipe safe, and `check || exit 1` is an explicit guard.
# A check that only appears after the git command is not this mistake.
#
# Bypass: '!'-prefix the command, or export SKIP_CHECK_CHAIN_GATE=1.

set -u

[ -n "${SKIP_CHECK_CHAIN_GATE:-}" ] && exit 0
command -v jq >/dev/null 2>&1 || exit 0

payload=$(cat 2>/dev/null) || exit 0
[ -n "$payload" ] || exit 0

cmd=$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null) || exit 0
[ -n "$cmd" ] || exit 0

case "$cmd" in
  *commit*|*push*) ;;
  *) exit 0 ;;
esac

verdict=$(printf '%s\n' "$cmd" | awk '
  { s = s (NR > 1 ? "\n" : "") $0 }
  END {
    s2 = " " s
    if (!match(s2, /[ \t\n;&|(]git[ \t]+(-C[ \t]+[^ \t]+[ \t]+)?(commit|push)([ \t\n;&|)]|$)/)) exit
    p = substr(s2, 1, RSTART)

    n = 0; seg = ""; q = ""; prev = ""; L = length(p)
    for (i = 1; i <= L; i++) {
      c = substr(p, i, 1); nx = substr(p, i + 1, 1)
      if (q != "") {
        seg = seg c
        if (c == q) q = ""
        else if (c == "\\" && q == "\"") { seg = seg nx; i++ }
        continue
      }
      if (c == "\047" || c == "\"") { q = c; seg = seg c; prev = c; continue }
      if (c == "\\") { seg = seg c nx; i++; prev = nx; continue }
      sep = ""
      if (c == "&" && nx == "&") { sep = "&&"; i++ }
      else if (c == "|" && nx == "|") { sep = "||"; i++ }
      else if (c == ";" || c == "\n") sep = c
      else if (c == "|") {
        if (prev == ">") { seg = seg c; prev = c; continue }
        sep = "|"; if (nx == "&") i++
      }
      else if (c == "&") {
        if (prev == ">" || prev == "<" || nx == ">") { seg = seg c; prev = c; continue }
        sep = "&"
      }
      if (sep != "") { n++; segs[n] = seg; seps[n] = sep; seg = ""; prev = ""; continue }
      seg = seg c; prev = c
    }

    first = 0
    for (k = 1; k <= n; k++) {
      if (segs[k] ~ /(^|[ \t\/(])((npm|pnpm|yarn|bun)([ \t]+run)?[ \t]+(lint|test|check|typecheck|type-check|build|format|verify)[^ \t]*|npx[ \t]+(tsc|vitest|jest|eslint|oxlint|biome|prettier)|tsc|vitest|jest|pytest|eslint|oxlint|biome|ruff|mypy|verify-run(\.sh)?|run-all\.sh|(cargo|go)[ \t]+(test|build|check|clippy|vet)|make[ \t]+(test|check|lint))([ \t]|$)/) { first = k; break }
    }
    if (!first) exit

    sete = (p ~ /set[ \t]+(-[a-zA-Z]*e|-o[ \t]+errexit)/)
    pipef = (p ~ /pipefail/)
    for (j = first; j <= n; j++) {
      sp = seps[j]
      if (sp == "&&") continue
      if ((sp == ";" || sp == "\n") && sete) continue
      if (sp == "|" && pipef) continue
      if (sp == "||" && j < n && segs[j + 1] ~ /^[ \t]*(exit|return|false)([ \t]|$)/) { j++; continue }
      chk = segs[j]; gsub(/^[ \t]+|[ \t]+$/, "", chk)
      if (length(chk) > 60) chk = substr(chk, 1, 57) "..."
      if (sp == "\n") sp = "a newline"
      else if (sp == "|") sp = "a pipe without pipefail"
      else if (sp == "&") sp = "a background &"
      else sp = "\047" sp "\047"
      print sp "\t" chk
      exit
    }
  }
')

[ -n "$verdict" ] || exit 0
sep_label=${verdict%%$'\t'*}
check_cmd=${verdict#*$'\t'}

"$(dirname "$0")/record-gate-block.sh" "pre-git-check-chain-gate" "$payload" 2>/dev/null || true
{
  echo "Blocked: the git commit/push runs after \`$check_cmd\` through $sep_label,"
  echo "which ignores the check's exit status — a failing check still commits."
  echo "Fix: join every step from the check to the git command with &&, or run"
  echo "the check on its own, read its result, then commit in the next command."
  echo "Bypass (human-only): '!'-prefix the command, or export SKIP_CHECK_CHAIN_GATE=1."
} >&2
exit 2
