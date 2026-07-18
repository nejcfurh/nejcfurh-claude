#!/usr/bin/env bash
# Regression tests for scripts/detect-parent-branch.sh.
#
# Each case builds a throwaway git repo, injects `origin/*` tracking refs, and
# stubs `gh` (both `repo view` and `pr list`) so the ranking logic can be
# exercised without a real GitHub remote. Run: bash detect-parent-branch.test.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="$SCRIPT_DIR/../scripts/detect-parent-branch.sh"

pass=0
fail=0

export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@test
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@test

commit() { # commit <msg> — empty commit, keeps topology explicit
  git commit -q --allow-empty -m "$1"
}

# Fake `gh` on PATH answering the two calls the script makes.
# $1 = stub dir, $2 = default branch, $3 = newline-separated PR head names.
make_gh_stub() {
  local dir="$1" default="$2" prs="$3"
  mkdir -p "$dir"
  cat >"$dir/gh" <<EOF
#!/bin/bash
case "\$*" in
  *"repo view"*)  echo "$default" ;;
  *"pr list"*)    printf '%s\n' $prs ;;
esac
EOF
  chmod +x "$dir/gh"
}

run_case() { # run_case <name> <expected> ; expects $repo and $stub prepared
  local name="$1" expected="$2" got
  got=$(cd "$repo" && PATH="$stub:$PATH" bash "$SUT" 2>/dev/null)
  if [ "$got" = "$expected" ]; then
    echo "PASS: $name (got '$got')"
    pass=$((pass + 1))
  else
    echo "FAIL: $name — expected '$expected', got '$got'"
    fail=$((fail + 1))
  fi
  rm -rf "$repo" "$stub"
}

track() { # track <branch> — expose a branch as origin/<branch>
  git update-ref "refs/remotes/origin/$1" "refs/heads/$1"
}

# ---------------------------------------------------------------------------
# Case 1: plain feature branch off main, no open PRs -> main.
# ---------------------------------------------------------------------------
repo=$(mktemp -d); stub=$(mktemp -d)
(
  cd "$repo" || exit 1
  git init -q -b main
  commit A
  git checkout -q -b feature
  commit B
  commit C
  track main
)
make_gh_stub "$stub" main ""
run_case "feature off main resolves to main" main

# ---------------------------------------------------------------------------
# Case 2: stacked branch — feature2 forked from feature1 (open PR). The
# closest ancestor must win over the default branch.
# ---------------------------------------------------------------------------
repo=$(mktemp -d); stub=$(mktemp -d)
(
  cd "$repo" || exit 1
  git init -q -b main
  commit A
  git checkout -q -b feature1
  commit B
  git checkout -q -b feature2
  commit C
  track main
  track feature1
)
make_gh_stub "$stub" main "feature1"
run_case "stacked branch resolves to its PR parent" feature1

# ---------------------------------------------------------------------------
# Case 3: stale sibling branch that forked from an older commit shares only
# an old ancestor — the default branch must win.
# ---------------------------------------------------------------------------
repo=$(mktemp -d); stub=$(mktemp -d)
(
  cd "$repo" || exit 1
  git init -q -b main
  commit ROOT
  git checkout -q -b stale
  commit X
  git checkout -q main
  commit M1
  git checkout -q -b feature
  commit F1
  commit F2
  track main
  track stale
)
make_gh_stub "$stub" main "stale"
run_case "stale sibling loses to main" main

# ---------------------------------------------------------------------------
# Case 4: an integration branch that MERGED an ancestor of HEAD is not a true
# base — the first-parent filter must reject it even though it is "closer".
# ---------------------------------------------------------------------------
repo=$(mktemp -d); stub=$(mktemp -d)
(
  cd "$repo" || exit 1
  git init -q -b main
  commit A
  git checkout -q -b feature
  commit B
  git checkout -q -b integration main
  git merge -q --no-ff -m "merge feature" feature
  git checkout -q feature
  commit C
  track main
  track integration
)
make_gh_stub "$stub" main "integration"
run_case "integration branch rejected by first-parent filter" main

# ---------------------------------------------------------------------------
# Case 5: two PR branches equally close — ambiguous, must fall back to main.
# ---------------------------------------------------------------------------
repo=$(mktemp -d); stub=$(mktemp -d)
(
  cd "$repo" || exit 1
  git init -q -b main
  commit A
  git checkout -q -b p1
  commit B
  git checkout -q -b p2
  commit D
  git checkout -q -b feature p1
  commit C
  # p2 contains B too, so both PR branches have merge-base B with HEAD.
  track main
  track p1
  track p2
)
make_gh_stub "$stub" main "p1 p2"
run_case "ambiguous PR tie falls back to main" main

# ---------------------------------------------------------------------------
# Case 6: already on the default branch -> the default branch.
# ---------------------------------------------------------------------------
repo=$(mktemp -d); stub=$(mktemp -d)
(
  cd "$repo" || exit 1
  git init -q -b main
  commit A
  track main
)
make_gh_stub "$stub" main ""
run_case "on main resolves to main" main

# ---------------------------------------------------------------------------
# Case 7: gh unavailable — falls back to origin/HEAD for the default branch.
# ---------------------------------------------------------------------------
repo=$(mktemp -d); stub=$(mktemp -d)
(
  cd "$repo" || exit 1
  git init -q -b trunk
  commit A
  git checkout -q -b feature
  commit B
  track trunk
  git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/trunk
)
mkdir -p "$stub"  # empty stub dir: no gh anywhere on the prefixed PATH entry
got=$(cd "$repo" && PATH="$stub:/usr/bin:/bin" bash "$SUT" 2>/dev/null)
if [ "$got" = "trunk" ]; then
  echo "PASS: gh unavailable falls back to origin/HEAD (got '$got')"
  pass=$((pass + 1))
else
  echo "FAIL: gh unavailable falls back to origin/HEAD — expected 'trunk', got '$got'"
  fail=$((fail + 1))
fi
rm -rf "$repo" "$stub"

echo ""
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
