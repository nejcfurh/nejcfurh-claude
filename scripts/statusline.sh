#!/usr/bin/env bash
# Claude Code status line renderer.
# Reads the statusline JSON payload on stdin and prints one colored line:
#   <cyan dir basename> │ <git branch[*]> │ <dim model name>
# The git segment is omitted outside a repo. Degrades to nothing without jq.

set -u

command -v jq >/dev/null 2>&1 || exit 0

payload=$(cat 2>/dev/null) || exit 0
[ -n "$payload" ] || exit 0

# One jq call for both fields.
vals=$(printf '%s' "$payload" \
  | jq -r '[(.workspace.current_dir // .cwd // ""), (.model.display_name // "")] | @tsv' 2>/dev/null) || exit 0
dir=$(printf '%s\n' "$vals" | cut -f1)
model=$(printf '%s\n' "$vals" | cut -f2)

CYAN=$'\033[36m'
YELLOW=$'\033[33m'
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

printf '%s\n' "$line"
exit 0
