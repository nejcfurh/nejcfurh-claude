#!/usr/bin/env bash
# Decides how much of the test suite /verify-done must run: only the tests
# related to the files this branch changes (mode=scoped), or everything
# (mode=full). Full is chosen whenever a changed file can affect tests it is
# not named in — CI and runner config, manifests and lockfiles, test
# infrastructure — or when a changed code file maps to no test at all.
#
# Changed files = everything differing from the merge-base with the PR base
# (committed, staged, unstaged, deleted) plus untracked, non-ignored files.
#
# Usage: verify-scope.sh [--base <ref>] [--full]
#   --base  the PR base to diff against (default: origin/<detect-parent-branch>)
#   --full  force mode=full (as does VERIFY_DONE_FULL=1)
#
# Output, one key=value per line (stdout):
#   mode=scoped|full
#   reason=<why>
#   base=<ref>
#   file=<path>        every changed file
#   native=<path>      changed JS/TS-family files, for vitest related / jest
#                      --findRelatedTests to map through the import graph
#   test=<path>        selected test files (shell suites, pytest), scoped only
#   selected=<n> total=<m>   selected vs. all name-mappable test files
set -u

base=""
force_full=0
[ -n "${VERIFY_DONE_FULL:-}" ] && force_full=1
while [ $# -gt 0 ]; do
  case "$1" in
    --base) base="${2:-}"; shift 2 ;;
    --full) force_full=1; shift ;;
    *) echo "verify-scope: unknown argument: $1" >&2; exit 2 ;;
  esac
done

repo=$(git rev-parse --show-toplevel 2>/dev/null) || {
  echo "verify-scope: not inside a git repository" >&2
  exit 2
}
cd "$repo" || exit 2

full() { # full <reason> — print the verdict and stop
  echo "mode=full"
  echo "reason=$1"
  echo "base=${base:-unknown}"
  [ -n "$changed_files" ] && printf '%s\n' "$changed_files" | sed 's/^/file=/'
  exit 0
}

changed_files=""

[ "$force_full" -eq 1 ] && full "full run requested"

if [ -z "$base" ]; then
  parent=$("$(dirname "$0")/detect-parent-branch.sh" 2>/dev/null)
  [ -n "$parent" ] && base="origin/$parent"
fi
[ -n "$base" ] || full "base branch could not be resolved"
mb=$(git merge-base "$base" HEAD 2>/dev/null) || full "no merge-base with $base"
[ -n "$mb" ] || full "no merge-base with $base"

changed_files=$(
  {
    git -c core.quotePath=false diff --name-only --no-renames "$mb" 2>/dev/null
    git -c core.quotePath=false ls-files --others --exclude-standard 2>/dev/null
  } | sort -u
)
[ -n "$changed_files" ] || full "no changes against $base"

all_tracked=$(git -c core.quotePath=false ls-files 2>/dev/null
  git -c core.quotePath=false ls-files --others --exclude-standard 2>/dev/null)
shell_suites=$(printf '%s\n' "$all_tracked" | grep -E '(^|/)[^/]+\.test\.sh$' | sort -u)
py_tests=$(printf '%s\n' "$all_tracked" | grep -E '(^|/)(test_[^/]+|[^/]+_test)\.py$' | sort -u)
mappable_tests=$(printf '%s\n%s\n' "$shell_suites" "$py_tests" | grep -v '^$' | sort -u)
total=$(printf '%s\n' "$mappable_tests" | grep -c . || true)

# --- Escalation triggers: files whose effect reaches tests not named after them.
is_trigger() {
  local f="$1" b
  b=$(basename "$f")
  case "$f" in
    .github/workflows/* | .circleci/* | .buildkite/* | .gitlab-ci.yml \
      | azure-pipelines.yml | Jenkinsfile)
      echo "CI config changed: $f"; return 0 ;;
  esac
  case "$b" in
    package.json | package-lock.json | yarn.lock | pnpm-lock.yaml \
      | pnpm-workspace.yaml | bun.lock | bun.lockb | requirements*.txt \
      | pyproject.toml | poetry.lock | uv.lock | Pipfile | Pipfile.lock \
      | setup.py | setup.cfg | go.mod | go.sum | Cargo.toml | Cargo.lock \
      | Gemfile | Gemfile.lock | .nvmrc | .node-version | .tool-versions)
      echo "manifest or lockfile changed: $f"; return 0 ;;
    tsconfig*.json | vitest.config.* | vitest.workspace.* | vite.config.* \
      | jest.config.* | jest.setup.* | jest.preset.* | babel.config.* \
      | .babelrc* | pytest.ini | tox.ini | conftest.py | turbo.json | nx.json \
      | setupTests.* | test-setup.* | vitest.setup.*)
      echo "test or build config changed: $f"; return 0 ;;
  esac
  case "/$f" in
    */__mocks__/* | */__fixtures__/* | */fixtures/* | */test-utils/* \
      | */testutils/* | */test-helpers/*)
      echo "test infrastructure changed: $f"; return 0 ;;
  esac
  # A non-test file inside a test directory is a helper, a runner or a fixture
  # every suite there may load.
  case "/$f" in
    */test/* | */tests/* | */__tests__/* | */spec/* | */e2e/*)
      if ! is_test_file "$f" && ! is_snapshot "$f"; then
        echo "test infrastructure changed: $f"; return 0
      fi ;;
  esac
  return 1
}

is_test_file() {
  case "$(basename "$1")" in
    *.test.* | *.spec.* | test_*.py | *_test.py | *_test.go) return 0 ;;
  esac
  return 1
}

is_snapshot() { case "$1" in */__snapshots__/*.snap) return 0 ;; esac; return 1; }

is_native() {
  case "$1" in
    *.js | *.jsx | *.ts | *.tsx | *.mjs | *.cjs | *.mts | *.cts | *.vue | *.svelte) return 0 ;;
  esac
  return 1
}

# Files no test executes: an unmapped one of these needs no escalation.
is_inert() {
  case "$(basename "$1")" in
    *.md | *.mdx | *.txt | *.rst | *.png | *.jpg | *.jpeg | *.gif | *.svg \
      | *.webp | *.ico | *.pdf | LICENSE* | CHANGELOG* | .gitignore \
      | .editorconfig | .prettierrc* | .prettierignore) return 0 ;;
  esac
  return 1
}

# Test files whose content names $1. Fixed-string match, so a dotted name is
# not a regex.
tests_mentioning() {
  [ -n "$mappable_tests" ] || return 0
  printf '%s\n' "$mappable_tests" | while IFS= read -r t; do
    [ -f "$t" ] && grep -qF -- "$1" "$t" 2>/dev/null && printf '%s\n' "$t"
  done
}

# Test files named after $1's stem: foo.sh -> foo.test.sh, foo.py -> test_foo.py
# or foo_test.py.
tests_named_for() {
  local b stem
  b=$(basename "$1")
  stem="${b%.*}"
  [ -n "$mappable_tests" ] || return 0
  printf '%s\n' "$mappable_tests" | while IFS= read -r t; do
    case "$(basename "$t")" in
      "$stem.test.sh" | "test_$stem.py" | "${stem}_test.py") printf '%s\n' "$t" ;;
    esac
  done
}

selected=""
native=""
while IFS= read -r f; do
  [ -n "$f" ] || continue
  if reason=$(is_trigger "$f"); then full "$reason"; fi

  if is_snapshot "$f"; then
    # __snapshots__/foo.test.ts.snap belongs to ../foo.test.ts.
    owner="$(dirname "$(dirname "$f")")/$(basename "$f" .snap)"
    [ -f "$owner" ] && native="$native
$owner"
    continue
  fi

  if is_native "$f"; then
    [ -f "$f" ] && native="$native
$f"
    continue
  fi

  hits=""
  if is_test_file "$f"; then
    [ -f "$f" ] && hits="$f"
  else
    hits="$(tests_named_for "$f")
$(tests_mentioning "$(basename "$f")")"
    if ! is_inert "$f"; then
      # One level of indirection: a sourced library reaches tests through the
      # scripts that load it, which are named after neither file.
      users=$(printf '%s\n' "$all_tracked" | grep -E '\.(sh|bash)$' | grep -vE '\.test\.sh$' \
        | while IFS= read -r s; do
          [ "$s" != "$f" ] && [ -f "$s" ] && grep -qF -- "$(basename "$f")" "$s" 2>/dev/null \
            && printf '%s\n' "$s"
        done)
      while IFS= read -r u; do
        [ -n "$u" ] && hits="$hits
$(tests_named_for "$u")"
      done <<<"$users"
    else
      # Docs are read by directory: a budget test globs rules/*.md, not a name.
      d=$(dirname "$f")
      [ "$d" != "." ] && hits="$hits
$(tests_mentioning "$d/")"
    fi
  fi
  hits=$(printf '%s\n' "$hits" | grep -v '^$' | sort -u)

  if [ -z "$hits" ]; then
    if [ ! -e "$f" ] && [ -z "$(tests_mentioning "$(basename "$f")")" ]; then
      continue # deleted, and nothing references it
    fi
    is_inert "$f" && continue
    full "no related test for changed file: $f"
  fi
  selected="$selected
$hits"
done <<<"$changed_files"

selected=$(printf '%s\n' "$selected" | grep -v '^$' | sort -u)
n=$(printf '%s\n' "$selected" | grep -c . || true)

if [ "$total" -gt 0 ] && [ $((n * 2)) -ge "$total" ]; then
  full "selection covers $n of $total test files — no cheaper than the full suite"
fi

echo "mode=scoped"
echo "reason=no escalation trigger matched"
echo "base=$base"
printf '%s\n' "$changed_files" | sed 's/^/file=/'
printf '%s\n' "$native" | grep -v '^$' | sort -u | sed 's/^/native=/'
printf '%s\n' "$selected" | grep -v '^$' | sed 's/^/test=/'
echo "selected=$n total=$total"
