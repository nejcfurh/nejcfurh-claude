#!/usr/bin/env bash
# Installs this config repo into ~/.claude via symlinks, so the repo stays the
# source of truth. Safe to re-run: correct links are skipped, existing real
# files/dirs are backed up to <path>.bak.<timestamp> first.
#
# Usage:
#   bash scripts/setup.sh --check   # dry-run, show what would change
#   bash scripts/setup.sh           # apply
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
CHECK=0
[ "${1:-}" = "--check" ] && CHECK=1

ITEMS=(
  "CLAUDE.md"
  "settings.json"
  "rules"
  "skills"
  "agents"
  "commands"
  "hooks"
  "scripts"
)

mkdir -p "$CLAUDE_DIR"

link_item() {
  local name="$1"
  local src="$REPO_DIR/$name"
  local dst="$CLAUDE_DIR/$name"

  if [ ! -e "$src" ]; then
    echo "SKIP    $name (missing in repo)"
    return
  fi

  if [ -L "$dst" ]; then
    if [ "$(readlink "$dst")" = "$src" ]; then
      echo "OK      $name (already linked)"
      return
    fi
    echo "RELINK  $name (symlink pointed elsewhere: $(readlink "$dst"))"
    [ "$CHECK" -eq 1 ] || rm "$dst"
  elif [ -e "$dst" ]; then
    echo "BACKUP  $name -> $name.bak.$TIMESTAMP, then link"
    [ "$CHECK" -eq 1 ] || mv "$dst" "$dst.bak.$TIMESTAMP"
  else
    echo "LINK    $name"
  fi

  [ "$CHECK" -eq 1 ] || ln -s "$src" "$dst"
}

echo "Repo:   $REPO_DIR"
echo "Target: $CLAUDE_DIR"
[ "$CHECK" -eq 1 ] && echo "(dry run - nothing will be changed)"
echo

for item in "${ITEMS[@]}"; do
  link_item "$item"
done

# Keep runtime noise Claude Code writes into settings.json out of git diffs.
if [ "$CHECK" -eq 0 ] && command -v jq >/dev/null 2>&1; then
  git -C "$REPO_DIR" config filter.strip-ephemeral-state.clean \
    'jq "del(.feedbackSurveyState)" 2>/dev/null || cat' || true
  git -C "$REPO_DIR" config filter.strip-ephemeral-state.smudge cat || true
fi

# Refactoring UI skills are installed from their source repo at setup time
# instead of being vendored here: the upstream LICENSE forbids redistribution.
if [ "$CHECK" -eq 0 ] && command -v claude >/dev/null 2>&1; then
  echo
  echo "Installing refactoring-ui plugin from source (not vendored - license)..."
  claude plugin marketplace add gnurio/refactoring-ui-plugin 2>/dev/null \
    || echo "  marketplace already added (or add failed - run manually: claude plugin marketplace add gnurio/refactoring-ui-plugin)"
  claude plugin install refactoring-ui-skills@refactoring-ui-plugin 2>/dev/null \
    || echo "  plugin already installed (or install failed - run manually: claude plugin install refactoring-ui-skills@refactoring-ui-plugin)"
fi

echo
echo "Done. Restart Claude Code sessions to pick up settings changes."
echo "Machine-local overrides go in $CLAUDE_DIR/settings.local.json (never symlinked)."
