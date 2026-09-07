#!/usr/bin/env bash
# Claude Code status line renderer.
# Reads the statusline JSON payload on stdin and prints one colored line:
#   <cyan dir> │ <git branch[*]> │ <dim model> │ <N% of context used> │ <dim greeting>
# The git segment is omitted outside a repo, the context segment whenever the
# percentage is unmeasured, and the greeting only appears when the global
# config's hooks dir is installed. Degrades to nothing without jq.

set -u

command -v jq >/dev/null 2>&1 || exit 0

payload=$(cat 2>/dev/null) || exit 0
[ -n "$payload" ] || exit 0

# One jq call for every field.
vals=$(printf '%s' "$payload" \
  | jq -r '[(.workspace.current_dir // .cwd // ""), (.model.display_name // ""),
            (.context_window.used_percentage // "" | tostring)] | @tsv' 2>/dev/null) || exit 0
dir=$(printf '%s\n' "$vals" | cut -f1)
model=$(printf '%s\n' "$vals" | cut -f2)
ctx_pct=$(printf '%s\n' "$vals" | cut -f3)

CYAN=$'\033[36m'
YELLOW=$'\033[33m'
RED=$'\033[31m'
DIM=$'\033[2m'
RESET=$'\033[0m'
SEP=" │ "

line=""

if [ -n "$dir" ]; then
  line="${CYAN}$(basename "$dir")${RESET}"
fi

if [ -n "$dir" ] && git -C "$dir" -c core.hooksPath=/dev/null rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  branch=$(git -C "$dir" -c core.hooksPath=/dev/null branch --show-current 2>/dev/null)
  [ -n "$branch" ] || branch=$(git -C "$dir" -c core.hooksPath=/dev/null rev-parse --short HEAD 2>/dev/null)
  if [ -n "$branch" ]; then
    dirty=""
    if [ -n "$(git -C "$dir" -c core.hooksPath=/dev/null status --porcelain --untracked-files=no 2>/dev/null)" ]; then
      dirty="${YELLOW}*${RESET}"
    fi
    seg="${branch}${dirty}"
    [ -n "$line" ] && line="${line}${SEP}${seg}" || line="$seg"
  fi
fi

if [ -n "$model" ]; then
  seg="${DIM}${model}${RESET}"
  [ -n "$line" ] && line="${line}${SEP}${seg}" || line="$seg"
fi

# Context usage, taken from the payload's own used_percentage rather than
# recomputed — Claude Code derives it input-only (input + cache reads + cache
# writes, excluding the response's output tokens), and matching that keeps this
# segment from drifting away from what /context and the footer report. Colour
# breaks at context-nudge.sh's 50/75/90 tiers so the two never disagree on
# screen. used_percentage is null early in a session and again after /compact,
# so a missing or non-numeric value drops the segment rather than rendering 0%
# — unmeasured is not empty, and the same guard keeps a malformed payload out of
# the integer comparison below.
ctx_pct=${ctx_pct%%.*}
case "$ctx_pct" in '' | *[!0-9]*) ctx_pct="" ;; esac
if [ -n "$ctx_pct" ]; then
  if [ "$ctx_pct" -ge 90 ]; then
    ctx_color="$RED"
  elif [ "$ctx_pct" -ge 50 ]; then
    ctx_color="$YELLOW"
  else
    ctx_color="$DIM"
  fi
  seg="${ctx_color}${ctx_pct}% of context used${RESET}"
  [ -n "$line" ] && line="${line}${SEP}${seg}" || line="$seg"
fi

if [ -d "$HOME/.claude/hooks" ]; then
  seg="${DIM}👋 Nejc's personal hooks, skills and gates active ✓${RESET}"
  [ -n "$line" ] && line="${line}${SEP}${seg}" || line="$seg"
fi

printf '%s\n' "$line"
exit 0
