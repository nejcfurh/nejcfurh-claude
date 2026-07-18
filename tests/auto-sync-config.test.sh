#!/usr/bin/env bash
# Regression tests for hooks/auto-sync-config.sh — the SessionStart hook that
# fast-forwards the config repo from origin. Each case runs against a
# throwaway upstream+clone pair and a throwaway HOME (the throttle stamp
# lives under $HOME/.claude/cache).
# Run: bash auto-sync-config.test.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# A failed mktemp must never leak this suite's git commands into the real repo.
cd "$(mktemp -d "${TMPDIR:-/tmp}/hooktest-cwd.XXXXXX")" || exit 1
SUT="$SCRIPT_DIR/../hooks/auto-sync-config.sh"

pass=0
fail=0

export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@test
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@test

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

make_pair() { # -> sets $upstream and $clone; clone is 1 commit behind
  upstream=$(mktemp -d "${TMPDIR:-/tmp}/hooktest-up.XXXXXX")
  (cd "$upstream" && git init -q -b main \
    && git config user.email test@test && git config user.name test \
    && echo one > CLAUDE.md && git add CLAUDE.md && git commit -q -m "chore: one")
  clone=$(mktemp -d "${TMPDIR:-/tmp}/hooktest-cl.XXXXXX")
  rmdir "$clone"
  git clone -q "$upstream" "$clone"
  git -C "$clone" config user.email test@test
  git -C "$clone" config user.name test
  (cd "$upstream" && echo two >> CLAUDE.md && git commit -q -am "chore: two")
}

fresh_home() {
  mktemp -d "${TMPDIR:-/tmp}/hooktest-home.XXXXXX"
}

# Behind, clean, on main -> fast-forwards.
make_pair
home=$(fresh_home)
out=$(HOME="$home" CLAUDE_CONFIG_REPO="$clone" bash "$SUT")
case "$out" in *"updated: pulled 1"*) rc=0 ;; *) rc=1 ;; esac
check "behind+clean+main pulls (said: ${out:-<silent>})" "$rc"
[ "$(git -C "$clone" rev-parse HEAD)" = "$(git -C "$upstream" rev-parse main)" ] && rc=0 || rc=1
check "clone HEAD matches upstream after pull" "$rc"
rm -rf "$upstream" "$clone" "$home"

# Behind but dirty -> notice, no merge.
make_pair
home=$(fresh_home)
echo local-change >> "$clone/CLAUDE.md"
before=$(git -C "$clone" rev-parse HEAD)
out=$(HOME="$home" CLAUDE_CONFIG_REPO="$clone" bash "$SUT")
case "$out" in *"local changes"*) rc=0 ;; *) rc=1 ;; esac
check "dirty repo gets a notice (said: ${out:-<silent>})" "$rc"
[ "$(git -C "$clone" rev-parse HEAD)" = "$before" ] && rc=0 || rc=1
check "dirty repo is left untouched" "$rc"
rm -rf "$upstream" "$clone" "$home"

# Behind but on another branch -> notice, no merge.
make_pair
home=$(fresh_home)
git -C "$clone" checkout -q -b other
out=$(HOME="$home" CLAUDE_CONFIG_REPO="$clone" bash "$SUT")
case "$out" in *"'other'"*) rc=0 ;; *) rc=1 ;; esac
check "non-main branch gets a notice (said: ${out:-<silent>})" "$rc"
rm -rf "$upstream" "$clone" "$home"

# Throttle: a fresh stamp skips the network entirely.
make_pair
home=$(fresh_home)
HOME="$home" CLAUDE_CONFIG_REPO="$clone" bash "$SUT" >/dev/null
(cd "$upstream" && echo three >> CLAUDE.md && git commit -q -am "chore: three")
out=$(HOME="$home" CLAUDE_CONFIG_REPO="$clone" bash "$SUT")
{ [ -z "$out" ] && [ "$(git -C "$clone" rev-parse HEAD)" != "$(git -C "$upstream" rev-parse main)" ]; } && rc=0 || rc=1
check "second run within throttle window is silent and pulls nothing" "$rc"
rm -rf "$upstream" "$clone" "$home"

# No CLAUDE_CONFIG_REPO -> repo derived from the ~/.claude/CLAUDE.md symlink.
make_pair
home=$(fresh_home)
mkdir -p "$home/.claude"
ln -s "$clone/CLAUDE.md" "$home/.claude/CLAUDE.md"
out=$(HOME="$home" bash "$SUT")
case "$out" in *"updated: pulled 1"*) rc=0 ;; *) rc=1 ;; esac
check "repo derived from CLAUDE.md symlink (said: ${out:-<silent>})" "$rc"
rm -rf "$upstream" "$clone" "$home"

# Neither env nor symlink -> silently does nothing.
home=$(fresh_home)
out=$(HOME="$home" bash "$SUT") && [ -z "$out" ] && rc=0 || rc=1
check "no repo locatable exits silently" "$rc"
rm -rf "$home"

echo ""
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
