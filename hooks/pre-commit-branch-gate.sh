#!/usr/bin/env bash
# PreToolUse (Bash, git commit): block commits made directly on main/master.
# Bypass: set SKIP_COMMIT_BRANCH_GATE to any non-empty value.

set -u

[ -n "${SKIP_COMMIT_BRANCH_GATE:-}" ] && exit 0
command -v jq >/dev/null 2>&1 || exit 0

payload=$(cat 2>/dev/null) || exit 0
[ -n "$payload" ] || exit 0

cmd=$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null) || exit 0

# shellcheck source=hooks/git-cmd-lib.sh
. "$(dirname "$0")/git-cmd-lib.sh"

# Every `git … commit` in the command, whatever git-level options precede it.
git_cmd_scan commit "$cmd"
[ "$GIT_CMD_N" -gt 0 ] || exit 0

# The hook runs BEFORE the command: a compound like `git checkout -b x && git
# commit …` will not be on branch x yet. Predict the branch at commit time by
# taking the LAST checkout/switch in the command portion before the commit.
# -B and -C (force-create) move the branch and check it out exactly as -b and
# -c do — omitting them let `git checkout -B main && git commit` predict the
# safe current branch and land on main.
pre_commit_part="${cmd%%commit*}"
switched=$(printf '%s\n' "$pre_commit_part" \
  | grep -oE "git[[:space:]]+(-C[[:space:]]+[^[:space:]]+[[:space:]]+)?(checkout[[:space:]]+-[bB]|switch[[:space:]]+-[cC]|checkout|switch)[[:space:]]+[^[:space:]&;|\"']+" \
  | tail -1 | awk '{print $NF}')

block() { # block <branch>
  "$(dirname "$0")/record-gate-block.sh" "pre-commit-branch-gate" "$payload" 2>/dev/null || true
  {
    echo "Blocked: commits directly to '$1' are not allowed."
    echo "Create a feature branch first: git checkout -b <type>/<topic>"
    echo "Bypass (human-only): '!'-prefix the command, or export SKIP_COMMIT_BRANCH_GATE=1 in your shell."
  } >&2
  exit 2
}

# Each invocation may target a different repo (`git -C <path> commit`), so
# resolve and check them all rather than only the first.
i=0
while [ "$i" -lt "$GIT_CMD_N" ]; do
  cpath="${GIT_CMD_CPATH[$i]}"
  i=$((i + 1))

  repo=$(git_cmd_repo "$cpath" "$cmd") || continue
  branch=$(git -C "$repo" branch --show-current 2>/dev/null)
  case "$switched" in
    -*|.|"") : ;;                    # flags, `checkout .`, nothing found — keep cwd branch
    *) branch="$switched" ;;
  esac

  case "$branch" in
    main|master) block "$branch" ;;
  esac
done

exit 0
