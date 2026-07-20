#!/usr/bin/env bash
# PreToolUse (Bash, git *): reject git's meta-execution surfaces that escape
# the subcommand gates or read files outside the repo —
#   git -c <cfg>          arbitrary config injection: alias.* / core.pager /
#                         core.hooksPath / core.fsmonitor all reach a shell
#   git --config-env …    same, with the value sourced from an env var
#   git --exec-path[=…]   relocates git's core programs -> binary hijack
#   git diff --no-index … turns git into a file reader for arbitrary paths,
#                         bypassing Read(**/.env)-style denies
# Runs first in the dispatcher and is subcommand-agnostic. `-c` / `--exec-path`
# are matched ONLY as git-LEVEL options (before the subcommand): a commit-level
# `git commit -c <commit>` reuses a message and stays allowed, as do `-C <path>`,
# `--git-dir`, and `--no-pager`. Known residuals (shared with every git gate):
# command substitution `$(git -c …)` and env-var injection (GIT_SSH_COMMAND=…,
# GIT_CONFIG_*) are not reachable here — the `Bash(git *)` matcher never routes
# a non-git-leading command to the dispatcher, and env-prefix forms are the
# sandbox layer's job.
# Bypass: set SKIP_GIT_META_GATE to any non-empty value.

set -u

[ -n "${SKIP_GIT_META_GATE:-}" ] && exit 0
command -v jq >/dev/null 2>&1 || exit 0

payload=$(cat 2>/dev/null) || exit 0
[ -n "$payload" ] || exit 0

cmd=$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null) || exit 0
[ -n "$cmd" ] || exit 0

# Join backslash-continued lines (a flag on a continuation line is still part
# of this invocation), then blank quoted spans so data cannot trip the scan
# (\047 = single quote; awk reads the whole input as one record via RS="\001").
cmd=$(printf '%s\n' "$cmd" | awk '{ if (sub(/\\$/, "")) printf "%s ", $0; else print }')
scan=$(printf '%s' "$cmd" | awk 'BEGIN{RS="\001"} {gsub("\"[^\"]*\"","\"\""); gsub("\047[^\047]*\047","\047\047"); printf "%s", $0}')

block() {
  "$(dirname "$0")/record-gate-block.sh" "pre-git-meta-gate" "$payload" 2>/dev/null || true
  {
    echo "Blocked: $1"
    echo "This git meta-option can run arbitrary commands or read files outside"
    echo "the repo, bypassing the subcommand gates and Read denies."
    echo "Bypass (human-only): '!'-prefix the command, or export SKIP_GIT_META_GATE=1 in your shell."
  } >&2
  exit 2
}

# Inspect one command segment's tokens. Git-level options precede the
# subcommand; -c / --exec-path there are the injection surface. After the
# subcommand only --no-index (git diff's arbitrary-file reader) matters.
scan_segment() {
  # Skip leading `VAR=val` env assignments before the command word.
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -*) break ;;
      *=*) shift ;;
      *) break ;;
    esac
  done
  [ "${1:-}" = "git" ] || return 0
  shift

  local in_opts=1 tok
  while [ "$#" -gt 0 ]; do
    tok="$1"; shift
    if [ "$in_opts" -eq 1 ]; then
      case "$tok" in
        -c|--config-env|--config-env=*|-c*)
          block "git config injection ('$tok') is not allowed." ;;
        --exec-path|--exec-path=*)
          block "git --exec-path relocates git's binaries ('$tok')." ;;
        -C|--git-dir|--work-tree|--namespace|--super-prefix)
          shift ;;  # consumes its argument, which is not a subcommand
        --git-dir=*|--work-tree=*|--namespace=*|--super-prefix=*)
          : ;;
        -*) : ;;  # other git-level flag (--no-pager, -p, --bare, --paginate …)
        *) in_opts=0 ;;  # first bareword is the subcommand
      esac
    else
      case "$tok" in
        --no-index|--no-index=*)
          block "git --no-index ('$tok') reads files outside the repo." ;;
      esac
    fi
  done
  return 0
}

# Quotes are already blanked, so ; & | are real command separators. Iterate in
# the current shell (here-doc, not a pipe) so block()'s exit 2 leaves the whole
# gate. noglob so a token like +refs/* or a pathspec is not expanded here.
set -f
while IFS= read -r segment; do
  # shellcheck disable=SC2086
  scan_segment $segment
done <<EOF
$(printf '%s\n' "$scan" | tr ';&|' '\n\n\n')
EOF
set +f
exit 0
