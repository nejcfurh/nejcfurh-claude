#!/usr/bin/env bash
# SessionStart: pull config-repo updates from origin so all devices stay in
# sync. Fast-forward only, and only when the repo is clean and on main;
# anything else prints a notice and leaves the repo untouched. Throttled via
# a stamp file so most session starts skip the network entirely.

set -u

# Locate the config repo through the symlink setup.sh created — a hardcoded
# clone path would break the "clone anywhere, run setup" install story.
repo="${CLAUDE_CONFIG_REPO:-}"
if [ -z "$repo" ] && [ -L "$HOME/.claude/CLAUDE.md" ]; then
  link_target=$(readlink "$HOME/.claude/CLAUDE.md")
  case "$link_target" in
    /*) repo=$(dirname "$link_target") ;;
  esac
fi
[ -n "$repo" ] || exit 0
stamp="$HOME/.claude/cache/config-repo-last-fetch"
interval=$((6 * 3600))

[ -d "$repo/.git" ] || exit 0

now=$(date +%s)
if [ -f "$stamp" ]; then
  last=$(cat "$stamp" 2>/dev/null || echo 0)
  case "$last" in *[!0-9]*) last=0 ;; esac
  [ $((now - last)) -lt "$interval" ] && exit 0
fi
mkdir -p "$(dirname "$stamp")"
printf '%s\n' "$now" >"$stamp"

cd "$repo" || exit 0

git fetch --quiet origin main 2>/dev/null || exit 0

behind=$(git rev-list --count HEAD..origin/main 2>/dev/null || echo 0)
[ "$behind" -gt 0 ] || exit 0

branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
if [ "$branch" != "main" ]; then
  echo "[config-sync] config repo is $behind commit(s) behind origin/main but checked out on '$branch' -- pull manually."
  exit 0
fi

if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
  echo "[config-sync] config repo is $behind commit(s) behind origin/main but has local changes -- pull manually."
  exit 0
fi

# Auto-merging executable config would let a compromised origin/main run code on
# every device unattended. Passive updates (rules, skills, agents, docs)
# fast-forward; any change under hooks/ or scripts/, or to settings.json, waits
# for a human to review the diff and merge -- ff-only proves history shape, not
# that the new code is trusted.
changed=$(git diff --name-only HEAD..origin/main 2>/dev/null)
if printf '%s\n' "$changed" | grep -Eq '^(hooks/|scripts/|settings\.json$)'; then
  echo "[config-sync] config repo is $behind commit(s) behind origin/main, but the update changes executable config (hooks/, scripts/, or settings.json) -- review and merge manually: (cd \"$repo\" && git log HEAD..origin/main && git merge --ff-only origin/main)"
  exit 0
fi

if git merge --ff-only --quiet origin/main 2>/dev/null; then
  echo "[config-sync] config repo updated: pulled $behind commit(s) from origin/main."
else
  echo "[config-sync] config repo is $behind commit(s) behind origin/main and cannot fast-forward -- resolve manually."
fi

exit 0
