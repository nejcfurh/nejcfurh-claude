#!/usr/bin/env bash
# PreToolUse (Bash, git *): block `git stash pop` / `git stash apply` that names
# no stash, while the stash list holds entries.
#
# Why this needs a gate rather than a note: the implicit target is stash@{0} —
# the most recent entry, which is not necessarily one this session created. A
# stash list is shared, long-lived and invisible: entries accumulate from other
# people's interrupted work and sit there for months. Popping the top of it
# applies someone else's changes into the current tree with no confirmation.
#
# The trap that motivates this is quieter still. `git stash push -- <pathspec>`
# that matches nothing tracked creates NO stash and says so only in passing; a
# `pop` written to undo it then reaches past it to whatever was already on the
# stack. Push-then-pop reads like a balanced pair, which is exactly why the
# mismatch goes unnoticed — and the changes land in a tree the author believes
# they just restored.
#
# Recovery is not guaranteed. A pop that applies cleanly DROPS the entry, so
# the other person's work exists only in the working tree it was dealt into.
# It survives a conflict only because git keeps the entry when it cannot apply.
#
# Blocks:  git stash pop / git stash apply  with no stash named, when
#          `git stash list` is non-empty.
# Allows:  an explicit entry (`git stash pop stash@{2}`) — naming it is the
#          deliberate act this gate wants; an empty stash list, where there is
#          nothing to take; and every other stash subcommand (push, save, list,
#          show, drop, branch, clear).
#
# Residuals: an explicit `stash@{0}` is allowed and can still be someone else's
# — the gate buys a look at the list, not a judgement about ownership. Entries
# this session created are indistinguishable from inherited ones, so a solo
# checkout pays a prompt it does not need; naming the entry clears it.
# Bypass: set SKIP_GIT_STASH_POP_GATE to any non-empty value.

set -u

[ -n "${SKIP_GIT_STASH_POP_GATE:-}" ] && exit 0
command -v jq >/dev/null 2>&1 || exit 0

payload=$(cat 2>/dev/null) || exit 0
[ -n "$payload" ] || exit 0

cmd=$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null) || exit 0
[ -n "$cmd" ] || exit 0

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$HOOK_DIR/git-cmd-lib.sh" 2>/dev/null || exit 0

block() { # block <action> <repo>
  "$HOOK_DIR/record-gate-block.sh" "pre-git-stash-pop-gate" "$payload" 2>/dev/null || true
  {
    echo "Blocked: 'git stash $1' with no entry named, and the stash list is not empty."
    echo "It would take stash@{0}, which is whatever is newest — not necessarily"
    echo "yours. Stash lists outlive sessions and collect other people's interrupted"
    echo "work. A pop that applies cleanly also drops the entry, so there is no copy"
    echo "left anywhere but the tree it just landed in."
    echo ""
    echo "Currently stashed in $2:"
    git -C "$2" stash list 2>/dev/null | head -5 | sed 's/^/  /'
    echo ""
    echo "Fix: read the list, then name the entry — git stash $1 'stash@{0}'."
    echo "If you meant to undo a 'git stash push' of your own, check it actually"
    echo "created one: a pathspec matching nothing tracked stashes nothing."
    echo "Bypass (human-only): '!'-prefix the command, or export SKIP_GIT_STASH_POP_GATE=1."
  } >&2
  exit 2
}

# Does this invocation name a stash entry, or ask for the top of the stack?
# Only a bareword argument can be an entry; every flag is a modifier.
names_an_entry() { # names_an_entry <args>
  local args="$1" tok seen_action=0
  while IFS= read -r tok; do
    case "$tok" in
      "") continue ;;
      pop|apply)
        # The action word itself, not a target.
        [ "$seen_action" -eq 0 ] && { seen_action=1; continue; }
        return 0
        ;;
      -*) continue ;;
      *) [ "$seen_action" -eq 1 ] && return 0 ;;
    esac
  done <<EOF
$args
EOF
  return 1
}

# Which of pop/apply this is, so the message names it back.
stash_action() { # stash_action <args>
  local args="$1" tok
  while IFS= read -r tok; do
    case "$tok" in
      pop|apply) printf '%s\n' "$tok"; return 0 ;;
    esac
  done <<EOF
$args
EOF
  return 1
}

git_cmd_scan stash "$cmd"

i=0
while [ "$i" -lt "${GIT_CMD_N:-0}" ]; do
  args="${GIT_CMD_ARGS[$i]}"
  cpath="${GIT_CMD_CPATH[$i]}"
  i=$((i + 1))

  action=$(stash_action "$args") || continue
  names_an_entry "$args" && continue

  repo=$(git_cmd_repo "$cpath") || continue

  # Nothing stashed means nothing to take; git's own error is the right one.
  [ -n "$(git -C "$repo" stash list 2>/dev/null)" ] || continue

  block "$action" "$repo"
done

exit 0
