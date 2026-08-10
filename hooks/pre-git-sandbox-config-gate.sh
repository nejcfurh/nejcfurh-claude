#!/usr/bin/env bash
# PreToolUse (Bash, git *): block git commands that write .git/config while the
# command sandbox is on.
#
# Measured: the sandbox denies the .git/config lock — "could not lock config
# file .git/config: Operation not permitted" — and it does so in every repo, not
# just one project (verified in two unrelated checkouts). The reason this needs a
# gate rather than a note is that the affected commands fail HALF-WAY:
#
#   git checkout -b <n> <start>  creates the branch ref, but HEAD never moves and
#                                the index is left holding <start>'s tree, so
#                                `git status` then shows a pile of staged files
#                                that look like someone else's work
#   git branch -d <n>            deletes the ref, orphans its [branch] section
#   git push -u <remote> <br>    publishes the branch, fails only the tracking
#                                write (so re-pushing is not the fix)
#
# Reconstructing which half applied costs far more than the retry, so this stops
# the command before it runs and names the fix. Blocks only forms that certainly
# write config; read-only forms stay allowed (`git config --get`, `git branch
# --list`, `git remote -v`, plain `git push`, plain `git checkout <existing>`).
#
# The sandbox flag is read from tool_input.dangerouslyDisableSandbox, which the
# payload carries as `true` when set and omits entirely when not — so the
# unsandboxed retry this gate asks for passes straight through.
#
# Residuals: `git branch <new> <remote-ref>` sets up tracking through a bareword
# form not parsed here, and `git worktree add` writes worktree metadata whose
# sandbox behaviour was not measured — both still fail sandboxed, just ungated.
# Bypass: set SKIP_GIT_SANDBOX_CONFIG_GATE to any non-empty value.

set -u

[ -n "${SKIP_GIT_SANDBOX_CONFIG_GATE:-}" ] && exit 0
command -v jq >/dev/null 2>&1 || exit 0

payload=$(cat 2>/dev/null) || exit 0
[ -n "$payload" ] || exit 0

cmd=$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null) || exit 0
[ -n "$cmd" ] || exit 0

# Already running unsandboxed: the config write will succeed, nothing to gate.
sandbox_disabled=$(printf '%s' "$payload" | jq -r '.tool_input.dangerouslyDisableSandbox // empty' 2>/dev/null)
[ "$sandbox_disabled" = "true" ] && exit 0

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$HOOK_DIR/git-cmd-lib.sh" 2>/dev/null || exit 0

block() { # block <what> <consequence>
  "$HOOK_DIR/record-gate-block.sh" "pre-git-sandbox-config-gate" "$payload" 2>/dev/null || true
  {
    echo "Blocked: $1 writes .git/config, which the command sandbox denies."
    echo "$2"
    echo "Fix: re-run this exact command with dangerouslyDisableSandbox: true."
    echo "Bypass (human-only): '!'-prefix the command, or export SKIP_GIT_SANDBOX_CONFIG_GATE=1."
  } >&2
  exit 2
}

# Does this invocation's argument list contain any of the given glob patterns?
args_have() { # args_have <args> <pattern…>
  local args="$1" tok pat
  shift
  while IFS= read -r tok; do
    for pat in "$@"; do
      # shellcheck disable=SC2254  # pattern is intentionally a glob
      case "$tok" in $pat) return 0 ;; esac
    done
  done <<EOF
$args
EOF
  return 1
}

# `git config` writes unless every argument is a read. Two barewords means a
# bare `git config <key> <value>` assignment. Flags that consume a value have
# their argument skipped so it is not miscounted as the value half.
config_is_write() { # config_is_write <args>
  local args="$1" tok barewords=0 skip=0
  while IFS= read -r tok; do
    if [ "$skip" -eq 1 ]; then skip=0; continue; fi
    case "$tok" in
      --unset|--unset-all|--remove-section|--rename-section|--add|--replace-all|--edit|-e)
        return 0 ;;
      --file|-f|--blob|--type|-t|--default)
        skip=1 ;;
      -*) : ;;
      *) barewords=$((barewords + 1)) ;;
    esac
  done <<EOF
$args
EOF
  [ "$barewords" -ge 2 ]
}

# `git remote`'s mutating subcommands. Its first bareword is the subcommand;
# plain `git remote`, `-v` and `show`/`get-url` only read.
remote_is_write() { # remote_is_write <args>
  local args="$1" tok
  while IFS= read -r tok; do
    case "$tok" in
      -*) continue ;;
      add|remove|rm|rename|set-url|set-head|set-branches|prune|update) return 0 ;;
      *) return 1 ;;
    esac
  done <<EOF
$args
EOF
  return 1
}

check() { # check <subcommand> <what> <consequence> <flag-pattern…>
  local sub="$1" what="$2" consequence="$3" i
  shift 3
  git_cmd_scan "$sub" "$cmd"
  i=0
  while [ "$i" -lt "${GIT_CMD_N:-0}" ]; do
    if args_have "${GIT_CMD_ARGS[$i]}" "$@"; then
      block "$what" "$consequence"
    fi
    i=$((i + 1))
  done
}

check checkout "git checkout -b" \
  "It half-applies: the branch ref is created, HEAD stays put, and the index is left holding the start point's tree." \
  '-b' '-B'

check switch "git switch -c" \
  "It half-applies the same way git checkout -b does: ref created, HEAD unmoved, index left dirty." \
  '-c' '-C'

check branch "this git branch flag" \
  "The ref change applies but its [branch] config section is left behind or unwritten." \
  '-d' '-D' '--delete' '-m' '-M' '--move' '--set-upstream-to' '--set-upstream-to=*' '--unset-upstream' '--edit-description'

check push "git push -u" \
  "The branch IS published and only the tracking write fails, so re-pushing is not the fix." \
  '-u' '--set-upstream'

git_cmd_scan config "$cmd"
i=0
while [ "$i" -lt "${GIT_CMD_N:-0}" ]; do
  if config_is_write "${GIT_CMD_ARGS[$i]}"; then
    block "this git config write" "Nothing is written and the command still reports success in a pipeline."
  fi
  i=$((i + 1))
done

git_cmd_scan remote "$cmd"
i=0
while [ "$i" -lt "${GIT_CMD_N:-0}" ]; do
  if remote_is_write "${GIT_CMD_ARGS[$i]}"; then
    block "this git remote change" "Remotes live in .git/config, so the change is silently lost."
  fi
  i=$((i + 1))
done

exit 0
