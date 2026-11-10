#!/usr/bin/env bash
# Regression tests for scripts/verify-scope.sh.
#
# /verify-done runs only the tests related to a branch's changed files, and
# the full suite whenever an edit can reach tests that are not named after
# it. Both directions matter: a missed escalation lets a scoped pass certify a
# break, and a needless one throws away the speed-up.
# Run: bash verify-scope.test.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# A failed mktemp must never leak this suite's git commands into the real repo.
cd "$(mktemp -d "${TMPDIR:-/tmp}/hooktest-cwd.XXXXXX")" || exit 1
SUT="$SCRIPT_DIR/../scripts/verify-scope.sh"

pass=0
fail=0

export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@test
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@test
unset VERIFY_DONE_FULL

check() { # check <name> <command…> — passes when the command exits 0
  local name="$1"
  shift
  if "$@"; then
    echo "PASS: $name"
    pass=$((pass + 1))
  else
    echo "FAIL: $name"
    fail=$((fail + 1))
  fi
}

repo=$(mktemp -d "${TMPDIR:-/tmp}/hooktest.XXXXXX")
outside=$(mktemp -d "${TMPDIR:-/tmp}/hooktest.XXXXXX")
(
  cd "$repo" && git init -q -b main \
    && mkdir -p hooks scripts tests rules src pkg .github/workflows \
    && printf 'echo foo\n' > hooks/foo.sh \
    && printf 'helper() { :; }\n' > hooks/shared-helper.sh \
    && printf '. "$(dirname "$0")/shared-helper.sh"\n' > hooks/bar.sh \
    && printf 'common\n' > hooks/common.sh \
    && printf 'echo orphan\n' > scripts/orphan.sh \
    && printf 'gone\n' > scripts/obsolete.sh \
    && printf 'bash hooks/foo.sh\n' > tests/foo.test.sh \
    && printf 'bash hooks/bar.sh\n' > tests/bar.test.sh \
    && printf 'cat rules/*.md\n' > tests/budget.test.sh \
    && for n in 1 2 3 4; do printf 'source hooks/common.sh\n' > "tests/filler$n.test.sh"; done \
    && printf 'for s in tests/*.test.sh; do bash "$s"; done\n' > tests/run-all.sh \
    && printf 'import mod\n' > tests/test_mod.py \
    && printf 'x = 1\n' > pkg/mod.py \
    && printf 'y = 1\n' > pkg/unmapped.py \
    && printf '# rule\n' > rules/a.md \
    && printf '# readme\n' > README.md \
    && printf 'export const a = 1\n' > src/app.ts \
    && printf 'name: ci\n' > .github/workflows/ci.yml \
    && printf '{}\n' > package.json \
    && git add -A && git commit -q -m "chore: init" \
    && git checkout -q -b work/topic
)

tip=$(git -C "$repo" rev-parse HEAD)

# Every case starts from the branch tip with a clean tree, including the cases
# that commit, stage a deletion or add untracked files.
reset_tree() {
  git -C "$repo" checkout -q -f -B work/topic "$tip" 2>/dev/null
  git -C "$repo" clean -fdq 2>/dev/null
}

scope() { (cd "$repo" && bash "$SUT" --base main "$@" 2>/dev/null); }

# expect <name> <mode> <setup-fn> [grep patterns that must appear…]
expect() {
  local name="$1" want="$2" setup="$3"
  shift 3
  reset_tree
  "$setup"
  local out
  out=$(scope)
  local ok=1
  printf '%s\n' "$out" | grep -qx "mode=$want" || ok=0
  local p
  for p in "$@"; do
    printf '%s\n' "$out" | grep -qxE -- "$p" || ok=0
  done
  if [ "$ok" -eq 1 ]; then
    echo "PASS: $name"
    pass=$((pass + 1))
  else
    echo "FAIL: $name"
    printf '%s\n' "$out" | sed 's/^/    /'
    fail=$((fail + 1))
  fi
}

lacks() { # lacks <pattern> — the last scope() output must not contain it
  ! scope | grep -qxE -- "$1"
}

# --- Scoped selection ---
edit_foo() { echo "# edit" >> "$repo/hooks/foo.sh"; }
expect "hook edit selects the suite named after it" scoped edit_foo \
  'test=tests/foo.test.sh' 'selected=1 total=8'
check "hook edit selects nothing else" lacks 'test=tests/bar.test.sh'

edit_lib() { echo "# edit" >> "$repo/hooks/shared-helper.sh"; }
expect "sourced library selects the tests of the scripts that source it" scoped edit_lib \
  'test=tests/bar.test.sh'

edit_test() { echo "# edit" >> "$repo/tests/foo.test.sh"; }
expect "edited test file selects itself" scoped edit_test 'test=tests/foo.test.sh'

edit_rule() { echo "more" >> "$repo/rules/a.md"; }
expect "doc read by directory selects the test that globs it" scoped edit_rule \
  'test=tests/budget.test.sh'

edit_readme() { echo "more" >> "$repo/README.md"; }
expect "unreferenced doc runs no tests and does not escalate" scoped edit_readme \
  'selected=0 total=8'

edit_ts() { echo "export const b = 2" >> "$repo/src/app.ts"; }
expect "TS file is handed to the native related-test runner" scoped edit_ts \
  'native=src/app.ts'

add_snap() {
  mkdir -p "$repo/src/__snapshots__"
  printf 'test\n' > "$repo/src/a.test.ts"
  printf 'snap\n' > "$repo/src/__snapshots__/a.test.ts.snap"
}
expect "snapshot maps to the test that owns it" scoped add_snap 'native=src/a.test.ts'

edit_py() { echo "z = 2" >> "$repo/pkg/mod.py"; }
expect "python module selects test_<module>.py" scoped edit_py 'test=tests/test_mod.py'

committed_edit() {
  echo "# edit" >> "$repo/hooks/foo.sh"
  git -C "$repo" commit -qam "chore: edit foo"
}
expect "committed edit on the branch is counted" scoped committed_edit \
  'test=tests/foo.test.sh' 'file=hooks/foo.sh'

untracked_pair() {
  printf 'echo new\n' > "$repo/hooks/new.sh"
  printf 'bash hooks/new.sh\n' > "$repo/tests/new.test.sh"
}
expect "untracked new hook and test are selected" scoped untracked_pair \
  'test=tests/new.test.sh' 'file=hooks/new.sh'

delete_unreferenced() { git -C "$repo" rm -q scripts/obsolete.sh; }
expect "deleting an unreferenced file does not escalate" scoped delete_unreferenced \
  'file=scripts/obsolete.sh' 'selected=0 total=8'

spaced_name() { printf 'doc\n' > "$repo/rules/with space.md"; }
expect "file name with a space is listed whole" scoped spaced_name \
  'file=rules/with space.md' 'test=tests/budget.test.sh'

# --- Escalation triggers ---
edit_orphan() { echo "# edit" >> "$repo/scripts/orphan.sh"; }
expect "code file with no related test escalates" full edit_orphan \
  'reason=no related test for changed file: scripts/orphan.sh'

edit_unmapped_py() { echo "y = 2" >> "$repo/pkg/unmapped.py"; }
expect "python module with no test escalates" full edit_unmapped_py \
  'reason=no related test for changed file: pkg/unmapped.py'

edit_runner() { echo "# edit" >> "$repo/tests/run-all.sh"; }
expect "test runner edit escalates" full edit_runner \
  'reason=test infrastructure changed: tests/run-all.sh'

edit_ci() { echo "on: push" >> "$repo/.github/workflows/ci.yml"; }
expect "CI workflow edit escalates" full edit_ci \
  'reason=CI config changed: .github/workflows/ci.yml'

edit_manifest() { echo '{"a":1}' > "$repo/package.json"; }
expect "package manifest edit escalates" full edit_manifest \
  'reason=manifest or lockfile changed: package.json'

add_lockfile() { printf 'lock\n' > "$repo/pnpm-lock.yaml"; }
expect "new lockfile escalates" full add_lockfile \
  'reason=manifest or lockfile changed: pnpm-lock.yaml'

add_tsconfig() { printf '{}\n' > "$repo/tsconfig.json"; }
expect "tsconfig edit escalates" full add_tsconfig \
  'reason=test or build config changed: tsconfig.json'

add_conftest() { printf 'import pytest\n' > "$repo/tests/conftest.py"; }
expect "conftest.py escalates" full add_conftest \
  'reason=test or build config changed: tests/conftest.py'

add_mock() { mkdir -p "$repo/src/__mocks__" && printf 'x\n' > "$repo/src/__mocks__/api.ts"; }
expect "__mocks__ edit escalates" full add_mock \
  'reason=test infrastructure changed: src/__mocks__/api.ts'

add_fixture() { mkdir -p "$repo/tests/fixtures" && printf 'x\n' > "$repo/tests/fixtures/data.json"; }
expect "fixture edit escalates" full add_fixture \
  'reason=test infrastructure changed: tests/fixtures/data.json'

edit_common() { echo "# edit" >> "$repo/hooks/common.sh"; }
expect "selection of half the suite or more escalates" full edit_common \
  'reason=selection covers 4 of 8 test files.*'

nothing() { :; }
expect "no changes against base escalates" full nothing \
  'reason=no changes against main'

# --- Forcing and failure modes ---
forced_flag() {
  reset_tree
  echo "# edit" >> "$repo/hooks/foo.sh"
  scope --full | grep -qx 'mode=full'
}
check "--full forces a full run" forced_flag

forced_env() {
  reset_tree
  echo "# edit" >> "$repo/hooks/foo.sh"
  (cd "$repo" && VERIFY_DONE_FULL=1 bash "$SUT" --base main 2>/dev/null) | grep -qx 'mode=full'
}
check "VERIFY_DONE_FULL=1 forces a full run" forced_env

bad_base() {
  reset_tree
  echo "# edit" >> "$repo/hooks/foo.sh"
  (cd "$repo" && bash "$SUT" --base no-such-ref 2>/dev/null) \
    | grep -qx 'reason=no merge-base with no-such-ref'
}
check "unresolvable base escalates instead of guessing" bad_base

outside_fails() { ! (cd "$outside" && bash "$SUT" --base main >/dev/null 2>&1); }
check "outside a repo exits non-zero" outside_fails

rm -rf "$repo" "$outside"

echo ""
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
