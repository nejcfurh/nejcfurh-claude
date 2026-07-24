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
ALLOW_NO_JQ=0
for arg in "$@"; do
  case "$arg" in
    --check) CHECK=1 ;;
    --allow-insecure-no-jq) ALLOW_NO_JQ=1 ;;
    *) echo "Unknown argument: $arg" >&2; exit 2 ;;
  esac
done

# Every git gate parses its hook payload with jq; the dispatcher now blocks git
# operations without it (fail closed). Installing anyway would ship a config
# whose entire git-enforcement layer refuses to run — so this is fatal, not a
# warning. --allow-insecure-no-jq opts out consciously.
if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is not installed. Every git quality gate (branch, force," >&2
  echo "       verify, author, secret, ...) parses its payload with jq, and" >&2
  echo "       the dispatcher blocks all git commands until it is present." >&2
  echo "       Install it first: brew install jq" >&2
  echo "       To install anyway (git gates will block): re-run with" >&2
  echo "       --allow-insecure-no-jq" >&2
  [ "$ALLOW_NO_JQ" -eq 1 ] || exit 1
  echo "       (continuing without jq at your request)" >&2
  echo >&2
fi
if ! command -v gitleaks >/dev/null 2>&1; then
  echo "note: gitleaks not found — the pre-commit secret gate falls back to"
  echo "      built-in patterns only. Recommended: brew install gitleaks"
  echo
fi

# "commands" stays listed after its removal from the repo so re-running setup
# cleans up the dangling ~/.claude/commands link on already-installed machines.
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

# --check is a dry run: it must not create the target either. This was the one
# unguarded mutation, so `CLAUDE_CONFIG_DIR=~/.cluade setup.sh --check` left a
# real directory behind on a typo.
[ "$CHECK" -eq 1 ] || mkdir -p "$CLAUDE_DIR"

link_item() {
  local name="$1"
  local src="$REPO_DIR/$name"
  local dst="$CLAUDE_DIR/$name"

  if [ ! -e "$src" ]; then
    # A link we created earlier whose repo source is gone would dangle
    # forever — remove it. Anything else in the way is not ours to touch.
    if [ -L "$dst" ] && [ "$(readlink "$dst")" = "$src" ]; then
      echo "UNLINK  $name (removed from repo)"
      [ "$CHECK" -eq 1 ] || rm "$dst"
    else
      echo "SKIP    $name (missing in repo)"
    fi
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

# Keep runtime noise Claude Code writes into settings.json out of git diffs:
# .feedbackSurveyState and .model. The active model is per-machine runtime
# state (Claude Code rewrites it into the symlinked settings.json on every
# /model), so tracking it means a perpetually dirty file; set it with /model
# or in settings.local.json instead.
#
# The driver is a script, not an inline `jq … || cat`: git pipes the file to the
# filter, so jq consumes stdin before it fails and the inline fallback has
# nothing left to replay — that staged a 0-byte settings.json, silently, whenever
# the file held a rebase conflict. See scripts/strip-ephemeral-state.sh.
#
# Path is repo-relative because git runs clean filters from the top of the
# working tree, so moving this clone does not break the driver. The -x guard
# keeps `git add settings.json` working on commits that predate the script
# (bisect, older branches), where it degrades to a pass-through.
if [ "$CHECK" -eq 0 ] && command -v jq >/dev/null 2>&1; then
  git -C "$REPO_DIR" config filter.strip-ephemeral-state.clean \
    '[ -x scripts/strip-ephemeral-state.sh ] && exec scripts/strip-ephemeral-state.sh || exec cat' || true
  git -C "$REPO_DIR" config filter.strip-ephemeral-state.smudge cat || true
elif [ "$CHECK" -eq 0 ]; then
  # git treats an undefined filter as a silent no-op, so skipping this quietly
  # meant the per-machine .model key got committed and every other machine hit a
  # perpetually dirty settings.json. Say so instead.
  echo
  echo "WARNING: jq not found, so the settings.json strip filter was NOT installed."
  echo "  Per-machine runtime state (.model) will show up as a diff and can be committed."
  echo "  Install jq and re-run this script to configure it."
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
echo "Machine-local env/permission overrides go in $CLAUDE_DIR/settings.json —"
echo "$CLAUDE_DIR/settings.local.json is NOT loaded (that variant is project-scoped only)."
