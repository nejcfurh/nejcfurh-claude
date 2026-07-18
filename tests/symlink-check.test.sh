#!/usr/bin/env bash
# Regression tests for hooks/symlink-check.sh — the SessionStart hook that
# warns when ~/.claude entries drift away from the config repo. Each case
# runs against a throwaway HOME and a throwaway fake repo.
# Run: bash symlink-check.test.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

cd "$(mktemp -d "${TMPDIR:-/tmp}/hooktest-cwd.XXXXXX")" || exit 1
SUT="$SCRIPT_DIR/../hooks/symlink-check.sh"

pass=0
fail=0

check() { # check <name> <condition-result>
  local name="$1" rc="$2"
  if [ "$rc" -eq 0 ]; then
    echo "PASS: $name"
    pass=$((pass + 1))
  else
    echo "FAIL: $name"
    fail=$((fail + 1))
  fi
}

# Must match ITEMS in the hook (lint-config.sh keeps that list honest).
ITEMS="CLAUDE.md settings.json rules skills agents hooks scripts"

make_repo() { # -> prints fake config repo path with all items present
  local r
  r=$(mktemp -d "${TMPDIR:-/tmp}/hooktest-repo.XXXXXX")
  local item
  for item in $ITEMS; do
    case "$item" in
      *.md|*.json) touch "$r/$item" ;;
      *) mkdir "$r/$item" ;;
    esac
  done
  printf '%s\n' "$r"
}

link_all() { # link_all <home> <repo>
  mkdir -p "$1/.claude"
  local item
  for item in $ITEMS; do
    ln -s "$2/$item" "$1/.claude/$item"
  done
}

# Everything linked -> silent (repo derived from the CLAUDE.md symlink).
repo=$(make_repo)
home=$(mktemp -d "${TMPDIR:-/tmp}/hooktest-home.XXXXXX")
link_all "$home" "$repo"
out=$(HOME="$home" bash "$SUT") && [ -z "$out" ] && rc=0 || rc=1
check "fully linked home is silent (said: ${out:-<silent>})" "$rc"

# One entry replaced by a real directory -> named in the warning.
rm "$home/.claude/rules"
mkdir "$home/.claude/rules"
out=$(HOME="$home" bash "$SUT")
case "$out" in *drifted*rules*) rc=0 ;; *) rc=1 ;; esac
check "drifted entry is named (said: ${out:-<silent>})" "$rc"
rm -rf "$home" "$repo"

# CLAUDE.md not a symlink and no env override -> setup pointer, not a guess.
home=$(mktemp -d "${TMPDIR:-/tmp}/hooktest-home.XXXXXX")
mkdir -p "$home/.claude"
touch "$home/.claude/CLAUDE.md"
out=$(HOME="$home" bash "$SUT")
case "$out" in *"not a symlink"*) rc=0 ;; *) rc=1 ;; esac
check "unlinked CLAUDE.md points at setup.sh (said: ${out:-<silent>})" "$rc"
rm -rf "$home"

# CLAUDE_CONFIG_REPO env override still works with nothing linked.
repo=$(make_repo)
home=$(mktemp -d "${TMPDIR:-/tmp}/hooktest-home.XXXXXX")
mkdir -p "$home/.claude"
out=$(HOME="$home" CLAUDE_CONFIG_REPO="$repo" bash "$SUT")
case "$out" in *"drifted or missing"*) rc=0 ;; *) rc=1 ;; esac
check "env-pointed repo reports all entries missing (said: ${out:-<silent>})" "$rc"
rm -rf "$home" "$repo"

echo ""
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
