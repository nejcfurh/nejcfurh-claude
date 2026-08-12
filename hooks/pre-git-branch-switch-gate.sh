#!/usr/bin/env bash
# PreToolUse (Bash, git *): block moving a checkout onto an existing branch while
# tracked files are modified.
#
# Why this needs a gate rather than a note: git ALLOWS this and says nothing. When
# the working-tree changes do not conflict with the target branch, `git checkout
# <branch>` carries them across and reports success. The changes are not lost, but
# they are now sitting on a branch they were never written for — and if they belong
# to someone else (a shared or primary checkout the agent did not put on its current
# branch), the agent has quietly taken over their workspace and staged their
# in-progress work alongside its own. Putting it back is not always clean: the
# return switch carries them again, and anything committed in between has to be
# unpicked by hand.
#
# The stale-read is what makes it hard to catch by attention: `git status` from
# earlier in the session says clean, someone edits a file, and the switch a minute
# later is judged against the old reading. Only a check at call time sees the truth.
#
# Blocks:  git checkout <existing-branch> / git switch <branch>  with modified
#          tracked files present.
# Allows:  `-b`/`-B`/`-c`/`-C` (starting a branch deliberately carries your work),
#          path restores (`git checkout -- <path>`, `git checkout <path>`), any
#          switch with a clean tracked tree, and untracked-only trees — untracked
#          files are not carried onto the branch, they simply stay put.
#
# Residuals: `git checkout -` (previous branch) parses as a flag, not a bareword,
# so it is not gated; a ref that is also a path on disk is treated as a path
# restore and allowed; `git worktree add` is a different subcommand and unaffected
# by design — a worktree is the fix this gate points at.
# Bypass: set SKIP_GIT_BRANCH_SWITCH_GATE to any non-empty value.

set -u

[ -n "${SKIP_GIT_BRANCH_SWITCH_GATE:-}" ] && exit 0
command -v jq >/dev/null 2>&1 || exit 0

payload=$(cat 2>/dev/null) || exit 0
[ -n "$payload" ] || exit 0

cmd=$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null) || exit 0
[ -n "$cmd" ] || exit 0

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$HOOK_DIR/git-cmd-lib.sh" 2>/dev/null || exit 0

block() { # block <target> <repo>
  "$HOOK_DIR/record-gate-block.sh" "pre-git-branch-switch-gate" "$payload" 2>/dev/null || true
  {
    echo "Blocked: switching to '$1' while tracked files are modified."
    echo "git carries uncommitted changes onto the target branch and reports success,"
    echo "so they end up on a branch they were not written for. If this checkout is"
    echo "not yours to move, those changes belong to whoever is editing it now."
    echo ""
    echo "Modified in $2:"
    git -C "$2" status --porcelain 2>/dev/null | grep -v '^??' | head -10 | sed 's/^/  /'
    echo ""
    echo "Fix: work in your own checkout — git worktree add <path> <branch> — or"
    echo "commit/stash the changes first if they are genuinely yours."
    echo "Bypass (human-only): '!'-prefix the command, or export SKIP_GIT_BRANCH_SWITCH_GATE=1."
  } >&2
  exit 2
}

# Does this invocation create a branch, or restore paths? Either way it is not a
# takeover of someone's checkout.
creates_or_restores() { # creates_or_restores <args>
  local args="$1" tok
  while IFS= read -r tok; do
    case "$tok" in
      -b|-B|-c|-C|--patch|-p|--ours|--theirs|--orphan|--detach) return 0 ;;
      --) return 0 ;;
    esac
  done <<EOF
$args
EOF
  return 1
}

# The first bareword — the thing being switched to.
first_bareword() { # first_bareword <args>
  local args="$1" tok skip=0
  while IFS= read -r tok; do
    if [ "$skip" -eq 1 ]; then skip=0; continue; fi
    case "$tok" in
      --start-point|--track|-t|--conflict|--pathspec-from-file) skip=1 ;;
      -*) : ;;
      "") : ;;
      *) printf '%s\n' "$tok"; return 0 ;;
    esac
  done <<EOF
$args
EOF
  return 1
}

check_switches() { # check_switches <subcommand>
  local sub="$1" i args target repo
  git_cmd_scan "$sub" "$cmd"
  i=0
  while [ "$i" -lt "${GIT_CMD_N:-0}" ]; do
    args="${GIT_CMD_ARGS[$i]}"
    i=$((i + 1))

    creates_or_restores "$args" && continue
    target=$(first_bareword "$args") || continue

    repo=$(git_cmd_repo "${GIT_CMD_CPATH[$((i - 1))]}") || continue

    # A name that exists on disk is a path restore, not a branch switch.
    [ -e "$repo/$target" ] && continue
    # Only gate things git can resolve as a ref; a typo is git's error to report.
    git -C "$repo" rev-parse --verify --quiet "$target" >/dev/null 2>&1 || continue
    # Already there — no switch, nothing carried.
    [ "$(git -C "$repo" rev-parse --abbrev-ref HEAD 2>/dev/null)" = "$target" ] && continue

    if git -C "$repo" status --porcelain 2>/dev/null | grep -qv '^??'; then
      block "$target" "$repo"
    fi
  done
}

check_switches checkout
check_switches switch

exit 0
