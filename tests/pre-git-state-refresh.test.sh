#!/usr/bin/env bash
# Regression tests for hooks/pre-git-state-refresh.sh.
#
# Asserts on the additionalContext emitted (or the silence) for each command
# shape. A stubbed failing `gh` exercises the no-open-pr path without the
# network. Run: bash pre-git-state-refresh.test.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# A failed mktemp must never leak this suite's git commands into the real repo.
cd "$(mktemp -d "${TMPDIR:-/tmp}/hooktest-cwd.XXXXXX")" || exit 1
SUT="$SCRIPT_DIR/../hooks/pre-git-state-refresh.sh"

pass=0
fail=0

export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@test
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@test
unset CLAUDE_PROJECT_DIR

check() { # check <name> <expected-substring-or-EMPTY> <actual-output>
  local name="$1" expected="$2" out="$3" ctx
  if [ "$expected" = "EMPTY" ]; then
    if [ -z "$out" ]; then
      echo "PASS: $name (no output)"
      pass=$((pass + 1))
    else
      echo "FAIL: $name — expected no output, got: $out"
      fail=$((fail + 1))
    fi
    return
  fi
  ctx=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null)
  case "$ctx" in
    *"$expected"*)
      echo "PASS: $name ($ctx)"
      pass=$((pass + 1))
      ;;
    *)
      echo "FAIL: $name — expected context containing '$expected', got: $ctx"
      fail=$((fail + 1))
      ;;
  esac
}

payload() { # payload <command-string>
  jq -n --arg cmd "$1" '{tool_input:{command:$cmd}}'
}

# Non-PR-related commands must produce NO output and NO API call.
out=$(payload 'ls -la' | bash "$SUT" 2>/dev/null)
check "unrelated command stays silent" EMPTY "$out"

out=$(payload 'cat README.md' | bash "$SUT" 2>/dev/null)
check "read command stays silent" EMPTY "$out"

# git push outside any repo -> not-a-repo marker.
nowhere=$(mktemp -d "${TMPDIR:-/tmp}/hooktest.XXXXXX")
out=$(payload 'git push' | (cd "$nowhere" && bash "$SUT") 2>/dev/null)
check "push outside a repo reports not-a-repo" "unavailable=not-a-repo" "$out"
rm -rf "$nowhere"

# git commit in a repo, with a stubbed gh that always fails -> no-open-pr.
repo=$(mktemp -d "${TMPDIR:-/tmp}/hooktest.XXXXXX")
stub=$(mktemp -d "${TMPDIR:-/tmp}/hooktest.XXXXXX")
cache=$(mktemp -d "${TMPDIR:-/tmp}/hooktest.XXXXXX")
printf '#!/bin/bash\nexit 1\n' > "$stub/gh"
chmod +x "$stub/gh"
(cd "$repo" && git init -q -b feat/x && git commit -q --allow-empty -m init)
out=$(payload 'git commit -m "feat: x"' \
  | (cd "$repo" && PATH="$stub:$PATH" PR_STATE_CACHE_DIR="$cache" bash "$SUT") 2>/dev/null)
check "commit with no PR reports no-open-pr" "branch=feat/x no-open-pr" "$out"
rm -rf "$repo" "$stub" "$cache"

# --- the ~60s cache: one GitHub round-trip per repo+branch, not one per call --
repo=$(mktemp -d "${TMPDIR:-/tmp}/hooktest.XXXXXX")
stub=$(mktemp -d "${TMPDIR:-/tmp}/hooktest.XXXXXX")
cache=$(mktemp -d "${TMPDIR:-/tmp}/hooktest.XXXXXX")
counter="$stub/calls"
printf '#!/bin/bash\necho x >> "%s"\nexit 1\n' "$counter" > "$stub/gh"
chmod +x "$stub/gh"
(cd "$repo" && git init -q -b feat/x && git commit -q --allow-empty -m init)

out=$(payload 'git push' \
  | (cd "$repo" && PATH="$stub:$PATH" PR_STATE_CACHE_DIR="$cache" bash "$SUT") 2>/dev/null)
check "first lookup queries gh" "no-open-pr" "$out"

out=$(payload 'git push' \
  | (cd "$repo" && PATH="$stub:$PATH" PR_STATE_CACHE_DIR="$cache" bash "$SUT") 2>/dev/null)
check "cached lookup still emits the context line" "no-open-pr" "$out"

calls=$(wc -l < "$counter" | tr -d '[:space:]')
if [ "$calls" = "1" ]; then
  echo "PASS: second lookup served from cache (1 gh call)"
  pass=$((pass + 1))
else
  echo "FAIL: second lookup served from cache — expected 1 gh call, got $calls"
  fail=$((fail + 1))
fi

# A stale cache entry must refetch.
touch -t 202601010000 "$cache"/* 2>/dev/null
out=$(payload 'git push' \
  | (cd "$repo" && PATH="$stub:$PATH" PR_STATE_CACHE_DIR="$cache" bash "$SUT") 2>/dev/null)
check "stale cache still emits the context line" "no-open-pr" "$out"
calls=$(wc -l < "$counter" | tr -d '[:space:]')
if [ "$calls" = "2" ]; then
  echo "PASS: stale cache refetches (2 gh calls)"
  pass=$((pass + 1))
else
  echo "FAIL: stale cache refetches — expected 2 gh calls, got $calls"
  fail=$((fail + 1))
fi
rm -rf "$repo" "$stub" "$cache"

# --- direct gh-pr wiring resolves the checkout from payload.cwd -------------
# Wired directly for `gh pr *`, this hook is not moved to the Bash tool's
# checkout by the dispatcher. It must resolve the repo from payload.cwd, not
# the process cwd — otherwise a worktree gh-pr flow reports the wrong branch's
# PR. Start the hook in a repo on `main`, point payload.cwd at a second repo on
# `feat/worktree`, and assert the emitted branch is the payload.cwd one.
wrongrepo=$(mktemp -d "${TMPDIR:-/tmp}/hooktest.XXXXXX")
rightrepo=$(mktemp -d "${TMPDIR:-/tmp}/hooktest.XXXXXX")
stub=$(mktemp -d "${TMPDIR:-/tmp}/hooktest.XXXXXX")
cache=$(mktemp -d "${TMPDIR:-/tmp}/hooktest.XXXXXX")
printf '#!/bin/bash\nexit 1\n' > "$stub/gh"
chmod +x "$stub/gh"
(cd "$wrongrepo" && git init -q -b main && git commit -q --allow-empty -m init)
(cd "$rightrepo" && git init -q -b feat/worktree && git commit -q --allow-empty -m init)
out=$(jq -n --arg cmd 'gh pr view' --arg cwd "$rightrepo" \
    '{tool_input:{command:$cmd},cwd:$cwd}' \
  | (cd "$wrongrepo" && PATH="$stub:$PATH" PR_STATE_CACHE_DIR="$cache" bash "$SUT") 2>/dev/null)
check "gh pr resolves branch from payload.cwd, not the process cwd" \
  "branch=feat/worktree no-open-pr" "$out"
rm -rf "$wrongrepo" "$rightrepo" "$stub" "$cache"

# --- fetch-age -------------------------------------------------------------
# The remote-ref age is appended to every emitted line so a stale checkout can
# never be read as current. It is local-only (a stat on FETCH_HEAD) and sits
# outside the PR cache, because staleness is the one thing it exists to report.
agerepo=$(mktemp -d "${TMPDIR:-/tmp}/hooktest.XXXXXX")
stub=$(mktemp -d "${TMPDIR:-/tmp}/hooktest.XXXXXX")
printf '#!/bin/bash\nexit 1\n' > "$stub/gh"
chmod +x "$stub/gh"
(cd "$agerepo" && git init -q -b main && git commit -q --allow-empty -m init)

age_out() { # run the hook against $agerepo with a stubbed gh and a cold cache
  jq -n --arg cmd 'git push' --arg cwd "$agerepo" \
      '{tool_input:{command:$cmd},cwd:$cwd}' \
    | PATH="$stub:$PATH" \
      PR_STATE_CACHE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/hookcache.XXXXXX")" \
      bash "$SUT" 2>/dev/null
}

absent() { # absent <name> <substring> <output> — substring gone, but a line WAS emitted
  # A bare "substring is missing" check passes just as happily when the hook
  # emitted nothing at all, which is how a crashed hook certifies itself green.
  # So silence is a failure here, not a pass.
  local ctx
  ctx=$(printf '%s' "$3" | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null)
  if [ -z "$ctx" ]; then
    echo "FAIL: $1 — no context emitted at all (a negative assertion must not pass on silence)"
    fail=$((fail + 1))
  elif printf '%s' "$ctx" | grep -q "$2"; then
    echo "FAIL: $1 — did not expect '$2' in: $ctx"
    fail=$((fail + 1))
  else
    echo "PASS: $1"
    pass=$((pass + 1))
  fi
}

# A repo with no remote has no fetch that could be stale, so the note stays off
# entirely — otherwise every local-only repo carries a permanent false warning.
out=$(age_out)
check "no-remote repo still reports PR state" "no-open-pr" "$out"
absent "no-remote repo omits fetch-age" "fetch-age" "$out"

git -C "$agerepo" remote add origin https://example.invalid/x.git

# A remote that has never been fetched is the worst case, not the quiet one.
check "remote but never fetched warns" "fetch-age=never WARNING" "$(age_out)"

# Fresh fetch: reported, never warned. Warning on every push would be noise that
# trains the reader to skip the line.
touch "$agerepo/.git/FETCH_HEAD"
out=$(age_out)
check "fresh fetch reports an age" "fetch-age=0m" "$out"
absent "fresh fetch does not warn" "WARNING" "$out"

# Past the threshold it must warn — this is the state that makes a three-dot
# diff or an ahead/behind count untrustworthy.
if touch -t "$(date -v-90M +%Y%m%d%H%M 2>/dev/null || date -d '-90 min' +%Y%m%d%H%M)" \
     "$agerepo/.git/FETCH_HEAD" 2>/dev/null; then
  check "stale fetch warns" "fetch-age=90m WARNING" "$(age_out)"
else
  echo "SKIP: stale fetch warns (no portable 'touch -t' here)"
fi

# The two stat flavours disagree in a way that is silent and platform-split:
# GNU reads `-f` as --file-system, so `stat -f %m FILE` answers about a
# filesystem instead of the file and puts non-numeric text on stdout. Feeding
# that to arithmetic leaves the counter unset, and `set -u` then kills a hook
# whose whole contract is that it never blocks. Simulate the GNU ordering here
# so the macOS runner covers the Linux path rather than only its own.
gnubin=$(mktemp -d "${TMPDIR:-/tmp}/hooktest.XXXXXX")
cat > "$gnubin/stat" <<'GNUSTUB'
#!/bin/bash
# Presents GNU semantics whatever the host's native flavour is: `-c FORMAT FILE`
# reads the file, `-f` is --file-system and so cannot take a format string. The
# absolute path avoids recursing into this stub. The delegation tries both
# syntaxes so the stub itself is portable - hardcoding one makes this case pass
# on the runner that shares that flavour and fail on the other.
if [ "$1" = "-c" ]; then
  v=$(/usr/bin/stat -c %Y "$3" 2>/dev/null || /usr/bin/stat -f %m "$3" 2>/dev/null)
  [ -n "$v" ] || exit 1
  printf '%s\n' "$v"
  exit 0
fi
if [ "$1" = "-f" ]; then
  echo "  File: \"$3\""
  echo "    ID: 0 Namelen: 255    Type: ext2/ext3"
  echo "stat: cannot read file system information for '$2'" >&2
  exit 1
fi
exec /usr/bin/stat "$@"
GNUSTUB
chmod +x "$gnubin/stat"
touch "$agerepo/.git/FETCH_HEAD"
if [ -x /usr/bin/stat ]; then
  out=$(jq -n --arg cmd 'git push' --arg cwd "$agerepo" \
      '{tool_input:{command:$cmd},cwd:$cwd}' \
    | PATH="$gnubin:$stub:$PATH" \
      PR_STATE_CACHE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/hookcache.XXXXXX")" \
      bash "$SUT" 2>/dev/null)
  check "a foreign stat flavour still emits a line" "[pr-state]" "$out"
  absent "a foreign stat flavour does not kill the hook" "fetch-age=unknown" "$out"
else
  echo "SKIP: foreign stat flavour (no /usr/bin/stat to delegate to)"
fi

rm -rf "$agerepo" "$stub" "$gnubin"

echo ""
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
