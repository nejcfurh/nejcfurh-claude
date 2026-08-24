#!/usr/bin/env bash
# PreToolUse (Bash, git *): block git commands that rewrite many working-tree
# files while the command sandbox is on.
#
# Sibling of pre-git-sandbox-config-gate.sh. That one covers .git/config writes;
# this one covers the working tree, which fails the same way for a different
# reason: the sandbox's write allowlist denies paths the checkout needs, and git
# reports "unable to unlink old '<path>': Operation not permitted" per file and
# then aborts — after having already written an unknown number of the others.
#
# Measured consequence of a sandboxed pull into a repo with denied paths (agent
# config directories, a lockfile): several hundred files were rewritten in the
# working tree, HEAD never moved, and `git status` showed a wall of modified
# files that looked like uncommitted work. Distinguishing "half-applied upstream
# content" from "someone's real edits" is the expensive part — the tree has to be
# diffed against the remote to tell them apart before anything can be discarded.
#
# So this stops the command and names the fix, rather than letting it half-run.
#
# Blocks: pull, merge, rebase, stash pop/apply, and checkout/switch of a branch
# or commit (a tree swap). Leaves alone: fetch (writes only .git refs/objects,
# which the sandbox allows), and checkout of specific paths.
#
# The sandbox flag is read from tool_input.dangerouslyDisableSandbox, which the
# payload carries as `true` when set and omits when not — so the unsandboxed
# retry this gate asks for passes straight through.
#
# Bypass: set SKIP_GIT_SANDBOX_TREE_GATE to any non-empty value.

set -u

[ -n "${SKIP_GIT_SANDBOX_TREE_GATE:-}" ] && exit 0
command -v jq >/dev/null 2>&1 || exit 0

payload=$(cat 2>/dev/null) || exit 0
[ -n "$payload" ] || exit 0

cmd=$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null) || exit 0
[ -n "$cmd" ] || exit 0

sandbox_off=$(printf '%s' "$payload" | jq -r '.tool_input.dangerouslyDisableSandbox // empty' 2>/dev/null)
[ "$sandbox_off" = "true" ] && exit 0

# Strip quoted strings so a commit message or branch name mentioning "pull"
# cannot trigger the gate.
scrubbed=$(printf '%s' "$cmd" | sed -e "s/'[^']*'/''/g" -e 's/"[^"]*"/""/g')

matched=""
case "$scrubbed" in
  *"git pull"*)   matched="git pull" ;;
  *"git merge"*)  matched="git merge" ;;
  *"git rebase"*) matched="git rebase" ;;
esac

if [ -z "$matched" ]; then
  case "$scrubbed" in
    *"git stash pop"*|*"git stash apply"*) matched="git stash pop/apply" ;;
  esac
fi

# checkout/switch that moves HEAD swaps the whole tree. `checkout -- <path>` and
# `checkout <ref> -- <path>` touch only the named paths, so leave those alone.
if [ -z "$matched" ]; then
  case "$scrubbed" in
    *" -- "*) : ;;
    *"git checkout"*|*"git switch"*) matched="git checkout/switch" ;;
  esac
fi

[ -n "$matched" ] || exit 0

cat >&2 <<EOF
Blocked: \`$matched\` under the command sandbox.

The sandbox denies writes to some paths a tree-rewriting git command needs, and
git aborts AFTER partially rewriting the working tree — HEAD does not move, so
the result looks like a pile of uncommitted changes that are actually
half-applied upstream content. Telling those apart from real edits costs far
more than the retry.

Fix: re-run this exact command with dangerouslyDisableSandbox: true.

If the tree is already in that state: diff it against the remote ref before
discarding anything — the files that match upstream are the half-applied ones.
Bypass this gate with SKIP_GIT_SANDBOX_TREE_GATE=1.
EOF
exit 2
