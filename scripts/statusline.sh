#!/usr/bin/env bash
# Claude Code status line renderer.
# Reads the statusline JSON payload on stdin and prints one colored line:
#   <cyan dir basename> │ <git branch[*]> │ <dim model name> │ <dim config greeting>
# The git segment is omitted outside a repo; the greeting only appears when the
# global config's hooks dir is installed. Degrades to nothing without jq.

set -u

command -v jq >/dev/null 2>&1 || exit 0

payload=$(cat 2>/dev/null) || exit 0
[ -n "$payload" ] || exit 0

# One jq call for every field.
vals=$(printf '%s' "$payload" \
  | jq -r '[(.workspace.current_dir // .cwd // ""), (.model.display_name // ""),
            (.context_window.used_percentage // "" | tostring),
            (.context_window.context_window_size // "" | tostring)] | @tsv' 2>/dev/null) || exit 0
dir=$(printf '%s\n' "$vals" | cut -f1)
model=$(printf '%s\n' "$vals" | cut -f2)
ctx_pct=$(printf '%s\n' "$vals" | cut -f3)
ctx_size=$(printf '%s\n' "$vals" | cut -f4)

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

# Context usage. The statusline payload is the only surface the harness hands the
# real window size to — Stop hooks get transcript_path and nothing else, which is
# why context-nudge.sh has to be told the size via CONTEXT_WINDOW_TOKENS. Colour
# breaks at that hook's own tiers so the two never disagree on screen.
# used_percentage is input-only and is null early in a session and after
# /compact, so a missing or non-numeric value drops the segment rather than
# rendering 0% — the same reason the git segment is omitted outside a repo.
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
  window=""
  case "$ctx_size" in
    '' | *[!0-9]*) : ;;
    *)
      if [ "$ctx_size" -ge 1000000 ]; then
        window=" of $((ctx_size / 1000000))M"
      elif [ "$ctx_size" -ge 1000 ]; then
        window=" of $((ctx_size / 1000))k"
      fi
      ;;
  esac
  seg="${ctx_color}${ctx_pct}%${window} ctx${RESET}"
  [ -n "$line" ] && line="${line}${SEP}${seg}" || line="$seg"
fi

if [ -d "$HOME/.claude/hooks" ]; then
  seg="${DIM}👋 Nejc's personal hooks, skills and gates active ✓${RESET}"
  [ -n "$line" ] && line="${line}${SEP}${seg}" || line="$seg"
fi

printf '%s\n' "$line"
exit 0
