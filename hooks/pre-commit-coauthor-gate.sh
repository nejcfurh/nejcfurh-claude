#!/usr/bin/env bash
# PreToolUse (Bash, git commit): block AI attribution footers in commit messages,
# including a message read from a file with -F/--file.
# PreToolUse (Write|Edit): block writing a Claude/Anthropic attribution trailer.
# A message file the agent writes can be committed through `!`, which runs in the
# user's shell where no agent hook fires; write time is the last point we see it.
# Bypass: set SKIP_COAUTHOR_GATE to any non-empty value.

set -u

[ -n "${SKIP_COAUTHOR_GATE:-}" ] && exit 0
command -v jq >/dev/null 2>&1 || exit 0

payload=$(cat 2>/dev/null) || exit 0
[ -n "$payload" ] || exit 0

block() { # block <first line of the reason>
  "$(dirname "$0")/record-gate-block.sh" "pre-commit-coauthor-gate" "$payload" 2>/dev/null || true
  {
    echo "$1"
    echo "Remove the 'Co-Authored-By' / 'Generated with Claude' attribution and retry."
    echo "Bypass (human-only): '!'-prefix the command, or export SKIP_COAUTHOR_GATE=1 in your shell."
  } >&2
  exit 2
}

tool=$(printf '%s' "$payload" | jq -r '.tool_name // empty' 2>/dev/null) || exit 0

case "$tool" in
  Write | Edit)
    text=$(printf '%s' "$payload" \
      | jq -r '.tool_input.content // .tool_input.new_string // empty' 2>/dev/null) || exit 0
    # Narrower than the commit check: only a trailer at line start naming
    # Claude/Anthropic, or the footer line itself. Prose that mentions either
    # mid-line, and human co-authors, stay writable.
    if printf '%s\n' "$text" | LC_ALL=C grep -Eiq \
      '^[[:space:]]*co-authored-by:.*(claude|anthropic)|^[^[:alnum:]]*generated with \[?claude code'; then
      block "Blocked: AI attribution is not allowed in this user's commits or commit message files."
    fi
    exit 0
    ;;
esac

cmd=$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null) || exit 0

# shellcheck source=hooks/git-cmd-lib.sh
. "$(dirname "$0")/git-cmd-lib.sh"

git_cmd_scan commit "$cmd"
[ "$GIT_CMD_N" -gt 0 ] || exit 0

# Contents of every -F/--file message file, resolved against the invocation's
# -C or `cd` directory as git would. `-F -` (stdin) and unreadable paths are skipped.
message_files() {
  local i tok want dir path
  for ((i = 0; i < GIT_CMD_N; i++)); do
    dir="${GIT_CMD_CPATH[$i]:-}"
    want=0
    while IFS= read -r tok; do
      path=""
      if [ "$want" -eq 1 ]; then
        path="$tok"
        want=0
      else
        case "$tok" in
          --file=*) path="${tok#--file=}" ;;
          --file | -F) want=1 ;;
          -F?*) path="${tok#-F}" ;;
        esac
      fi
      [ -n "$path" ] && [ "$path" != "-" ] || continue
      case "$path" in
        /*) : ;;
        *) [ -n "$dir" ] && path="$dir/$path" ;;
      esac
      [ -r "$path" ] && cat "$path" 2>/dev/null
    done <<EOF
${GIT_CMD_ARGS[$i]}
EOF
  done
}

lower=$(printf '%s\n%s' "$cmd" "$(message_files)" | tr '[:upper:]' '[:lower:]')
case "$lower" in
  *"co-authored-by"*|*"generated with claude"*)
    block "Blocked: AI attribution is not allowed in this user's commits."
    ;;
esac

exit 0
