#!/usr/bin/env bash
# Regression tests for scripts/strip-ephemeral-state.sh — the git clean filter
# for settings.json.
#
# The bug these exist for: the driver used to be `jq … 2>/dev/null || cat`
# inline in git config. git pipes the file to a clean filter, so jq consumed all
# of stdin before failing and `cat` had nothing left to replay — the filter
# emitted nothing, git staged a 0-BYTE blob, and exited 0 without a warning.
# Invalid JSON is exactly what a rebase conflict leaves in settings.json.
#
# The invariant asserted throughout: non-empty input never yields empty output.
# Run: bash strip-ephemeral-state.test.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SUT="$REPO_ROOT/scripts/strip-ephemeral-state.sh"

# A failed mktemp must never leak this suite's git commands into the real repo.
cd "$(mktemp -d "${TMPDIR:-/tmp}/hooktest-cwd.XXXXXX")" || exit 1

pass=0
fail=0

export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@test
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@test

check() { # check <name> <expected> <actual>
  if [ "$2" = "$3" ]; then
    echo "PASS: $1"
    pass=$((pass + 1))
  else
    echo "FAIL: $1 — expected '$2', got '$3'"
    fail=$((fail + 1))
  fi
}

# The conflict-marked settings.json a rebase leaves behind: not valid JSON.
conflicted() {
  cat <<'EOF'
<<<<<<< HEAD
{"permissions":{"deny":["Bash(rm -rf *)"]},"hooks":{"PreToolUse":[]}}
=======
{"permissions":{"deny":["Bash(rm -rf *)","Bash(git push*)"]}}
>>>>>>> origin/main
EOF
}

# --- the filter in isolation ---------------------------------------------------

# Ephemeral keys are what the filter exists to remove.
valid='{"model":"opus","feedbackSurveyState":{"x":1},"permissions":{"deny":["Bash(rm -rf *)"]}}'
out=$(printf '%s\n' "$valid" | bash "$SUT")
check "valid JSON: .model stripped"               ""     "$(printf '%s' "$out" | jq -r '.model // ""')"
check "valid JSON: .feedbackSurveyState stripped" ""     "$(printf '%s' "$out" | jq -r '.feedbackSurveyState // ""')"
check "valid JSON: real settings kept"            "Bash(rm -rf *)" \
  "$(printf '%s' "$out" | jq -r '.permissions.deny[0]')"

# Valid JSON with nothing to strip must survive semantically intact.
plain='{"permissions":{"allow":["Bash(git *)"]}}'
out=$(printf '%s\n' "$plain" | bash "$SUT")
check "valid JSON without ephemeral keys survives" "true" \
  "$(printf '%s' "$out" | jq --argjson want "$plain" -e '. == $want' 2>/dev/null || echo false)"

# THE BUG: invalid JSON must be staged exactly as it is on disk, never emptied.
in_bytes=$(conflicted | wc -c | tr -d ' ')
out_bytes=$(conflicted | bash "$SUT" | wc -c | tr -d ' ')
check "conflict markers: output is not empty" "yes" "$([ "$out_bytes" -gt 0 ] && echo yes || echo no)"
check "conflict markers: byte-identical passthrough" "$in_bytes" "$out_bytes"
check "conflict markers: content identical" "yes" \
  "$([ "$(conflicted | bash "$SUT" | cksum)" = "$(conflicted | cksum)" ] && echo yes || echo no)"

# Other malformed shapes take the same path.
truncated='{"permissions":{"deny":["Bash(rm'
check "truncated JSON passes through" "$truncated" "$(printf '%s' "$truncated" | bash "$SUT")"

trailing='{"a":1} then some prose'
check "valid prefix plus garbage passes through whole" "$trailing" \
  "$(printf '%s' "$trailing" | bash "$SUT")"

not_json='this is not json at all'
check "plain text passes through" "$not_json" "$(printf '%s' "$not_json" | bash "$SUT")"

# Empty in, empty out is correct — there was no content to lose.
check "empty input yields empty output" "0" "$(printf '' | bash "$SUT" | wc -c | tr -d ' ')"

# A jq-less machine must also pass content through, not empty it. The stub bin
# needs `bash` itself: PATH applies to resolving the interpreter too.
nojq_bin=$(mktemp -d "${TMPDIR:-/tmp}/nojqbin.XXXXXX")
for b in bash cat mktemp rm; do
  src=$(command -v "$b") && ln -s "$src" "$nojq_bin/$b"
done
[ -x "$nojq_bin/bash" ] || echo "WARN: stub bin lacks bash — no-jq cases would be vacuous"
out_bytes=$(conflicted | PATH="$nojq_bin" bash "$SUT" | wc -c | tr -d ' ')
check "no jq: conflict markers still pass through" "$in_bytes" "$out_bytes"
out=$(printf '%s\n' "$valid" | PATH="$nojq_bin" bash "$SUT")
check "no jq: valid JSON passes through unstripped" "opus" "$(printf '%s' "$out" | jq -r '.model')"

# --- end to end, through git ---------------------------------------------------

make_repo() { # make_repo -> prints repo path with the filter wired up
  local r
  r=$(mktemp -d "${TMPDIR:-/tmp}/hooktest.XXXXXX")
  (
    cd "$r" || exit 1
    git init -q -b main
    mkdir -p scripts
    cp "$SUT" scripts/strip-ephemeral-state.sh
    chmod +x scripts/strip-ephemeral-state.sh
    printf 'settings.json filter=strip-ephemeral-state\n' > .gitattributes
    git config filter.strip-ephemeral-state.clean \
      '[ -x scripts/strip-ephemeral-state.sh ] && exec scripts/strip-ephemeral-state.sh || exec cat'
    git config filter.strip-ephemeral-state.smudge cat
    git add .gitattributes scripts
    git commit -q -m init
  ) >/dev/null 2>&1
  printf '%s\n' "$r"
}

# Staging a conflicted settings.json must stage its real bytes. This is the
# regression: `git add` used to succeed and stage nothing at all.
r1=$(make_repo)
conflicted > "$r1/settings.json"
git -C "$r1" add settings.json
staged=$(git -C "$r1" cat-file -s :settings.json 2>/dev/null || echo missing)
worktree=$(wc -c < "$r1/settings.json" | tr -d ' ')
check "git add of conflicted settings.json stages its bytes" "$worktree" "$staged"

# And the normal path still strips.
r2=$(make_repo)
printf '%s\n' "$valid" > "$r2/settings.json"
git -C "$r2" add settings.json
check "git add of valid settings.json strips .model" "" \
  "$(git -C "$r2" cat-file -p :settings.json | jq -r '.model // ""')"
check "git add of valid settings.json keeps real settings" "Bash(rm -rf *)" \
  "$(git -C "$r2" cat-file -p :settings.json | jq -r '.permissions.deny[0]')"

# A checkout must reproduce the file the filter stored (smudge is `cat`).
git -C "$r2" commit -q -m "chore: settings"
git -C "$r2" checkout -q -- settings.json
check "round trip leaves a non-empty worktree file" "yes" \
  "$([ -s "$r2/settings.json" ] && echo yes || echo no)"

# Commits predating the script (bisect, older branches) have the driver
# configured but no script present — the -x guard degrades to pass-through
# instead of failing the add or staging nothing.
r3=$(make_repo)
rm -f "$r3/scripts/strip-ephemeral-state.sh"
conflicted > "$r3/settings.json"
git -C "$r3" add settings.json 2>/dev/null
rc=$?
check "missing driver script: git add still succeeds" "0" "$rc"
check "missing driver script: bytes still staged" "$worktree" \
  "$(git -C "$r3" cat-file -s :settings.json 2>/dev/null || echo missing)"

rm -rf "$r1" "$r2" "$r3" "$nojq_bin"

echo ""
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
