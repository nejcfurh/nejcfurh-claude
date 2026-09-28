#!/usr/bin/env bash
# PostToolUse (Bash, gh *): once `gh pr create` has opened a PR, move the checkout
# back to the PR's base branch and fast-forward it, so the next task starts from
# an up-to-date base instead of from the branch that is now under review.
#
# Only a main checkout moves. A linked worktree exists to hold its branch — the
# ticket and review skills reopen it — so it is left alone. A dirty tree is left
# alone too: switching would carry the uncommitted changes onto the base.
#
# The PR is confirmed with `gh pr view`, not inferred from the command: a failed
# create leaves nothing to return from, and `--head <other>` opens a PR for a
# branch that is not the one checked out.
#
# The config repo is switched but never pulled here. Its updates run as hooks on
# every session, so they go through auto-sync-config.sh's passive-path hold.
#
# Non-blocking and advisory, so no bypass: unwire it in settings.json to stop it.

set -u

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=hook-output-lib.sh
. "$HOOK_DIR/hook-output-lib.sh"
# shellcheck source=git-cmd-lib.sh
. "$HOOK_DIR/git-cmd-lib.sh"

segment_is_pr_create() { # segment_is_pr_create <token…>
  while [ "$#" -gt 0 ]; do
    case "$1" in
      sudo|doas|env|command|nice|time|nohup|stdbuf|-*|*=*) shift ;;
      *) break ;;
    esac
  done
  [ "${1:-}" = "gh" ] && [ "${2:-}" = "pr" ] && [ "${3:-}" = "create" ]
}

# The shared tokenizer, so `gh pr create` inside a quoted --body or an echo is
# data, not a create. Residual: a heredoc body line that starts with those words.
opens_pr() { # opens_pr <command-string>
  local line
  local -a toks=()
  while IFS= read -r line; do
    case "$line" in
      T*) toks[${#toks[@]}]="${line#T}"; continue ;;
    esac
    if [ "${#toks[@]}" -gt 0 ]; then
      segment_is_pr_create "${toks[@]}" && return 0
      toks=()
    fi
  done <<EOF
$(printf '%s' "$1" | _git_cmd_tokenize)
EOF
  [ "${#toks[@]}" -gt 0 ] && segment_is_pr_create "${toks[@]}"
}

payload=$(cat 2>/dev/null) || exit 0
command -v jq >/dev/null 2>&1 || exit 0

cmd=$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null) || exit 0
opens_pr "$cmd" || exit 0

# The hook process starts in the session's original project dir, not the
# checkout the Bash tool is in after a persisted `cd`.
payload_cwd=$(printf '%s' "$payload" | jq -r '.cwd // empty' 2>/dev/null)
if [ -n "$payload_cwd" ] && [ -d "$payload_cwd" ]; then
  cd "$payload_cwd" 2>/dev/null || exit 0
fi

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0

dirs=$(git rev-parse --path-format=absolute --git-dir --git-common-dir 2>/dev/null) || exit 0
[ "$(printf '%s\n' "$dirs" | sed -n 1p)" = "$(printf '%s\n' "$dirs" | sed -n 2p)" ] || exit 0

branch=$(git symbolic-ref --quiet --short HEAD 2>/dev/null) || exit 0

pr=$(gh pr view --json number,state,baseRefName,headRefName 2>/dev/null) || exit 0
state=$(printf '%s' "$pr" | jq -r '.state // empty')
head=$(printf '%s' "$pr" | jq -r '.headRefName // empty')
base=$(printf '%s' "$pr" | jq -r '.baseRefName // empty')
number=$(printf '%s' "$pr" | jq -r '.number // empty')
[ "$state" = "OPEN" ] && [ "$head" = "$branch" ] && [ -n "$base" ] || exit 0
[ "$base" != "$branch" ] || exit 0

if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
  hook_warn PostToolUse <<EOF
[return-to-base] PR #$number is open, but the checkout stayed on '$branch': it has uncommitted changes, and switching would carry them onto '$base'.
EOF
  exit 0
fi

if ! git switch --quiet "$base" 2>/dev/null; then
  hook_warn PostToolUse <<EOF
[return-to-base] PR #$number is open, but switching from '$branch' to '$base' failed. The checkout is still on '$branch'.
EOF
  exit 0
fi

next="Further work on PR #$number needs \`git switch $branch\` or a worktree."

config_repo="${CLAUDE_CONFIG_REPO:-}"
if [ -z "$config_repo" ] && [ -L "$HOME/.claude/CLAUDE.md" ]; then
  link_target=$(readlink "$HOME/.claude/CLAUDE.md")
  case "$link_target" in
    /*) config_repo=$(dirname "$link_target") ;;
  esac
fi
toplevel=$(git rev-parse --show-toplevel 2>/dev/null)
if [ -n "$config_repo" ] && [ -d "$config_repo" ] \
  && [ "$(cd "$config_repo" && pwd -P)" = "$(cd "$toplevel" && pwd -P)" ]; then
  hook_warn PostToolUse <<EOF
[return-to-base] PR #$number is open; switched from '$branch' to '$base'. Not pulled: config-repo updates go through the session-start sync. $next
EOF
  exit 0
fi

upstream=$(git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null) || upstream=""
if [ -z "$upstream" ]; then
  hook_warn PostToolUse <<EOF
[return-to-base] PR #$number is open; switched from '$branch' to '$base'. Not pulled: '$base' has no upstream. $next
EOF
  exit 0
fi

remote=$(git config --get "branch.$base.remote" 2>/dev/null) || remote=""
if [ -n "$remote" ] && git fetch --quiet "$remote" 2>/dev/null \
  && git merge --ff-only --quiet '@{upstream}' 2>/dev/null; then
  result="fast-forwarded to $upstream"
else
  result="but could not fast-forward to $upstream — pull it by hand"
fi

hook_warn PostToolUse <<EOF
[return-to-base] PR #$number is open; switched from '$branch' to '$base', $result. $next
EOF
exit 0
