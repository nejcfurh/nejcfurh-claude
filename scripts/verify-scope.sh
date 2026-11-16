#!/usr/bin/env bash
# Decides how much of the test suite /verify-done must run: only the tests
# related to the files this branch changes (mode=scoped), or everything
# (mode=full). Full is chosen whenever a changed file can affect tests it is
# not named in — CI and runner config, manifests and lockfiles, test
# infrastructure, a new non-JS/TS code file — or when a changed code file maps
# to no test at all. Tests that enumerate a directory (route censuses,
# registries, "every X has a Y" checks) reach a new file by listing, never by
# import or by name. For a new JS/TS file those tests are found by content and
# added to native=, so the run stays scoped; when none can be found, or the
# new file is not JS/TS, the run goes full.
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

added_files=$(
  {
    git -c core.quotePath=false diff --name-only --no-renames --diff-filter=A "$mb" 2>/dev/null
    git -c core.quotePath=false ls-files --others --exclude-standard 2>/dev/null
  } | sort -u
)

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

# JS/TS test files that list directories instead of importing what they check
# (route censuses, "every X has a Y" checks): a new file reaches them by
# listing alone, so the import graph never selects them. Found at run time, so
# a new census test is covered the day it lands. A scanning helper inside a
# test directory brings in every test file that names it.
native_globs=('*.js' '*.jsx' '*.ts' '*.tsx' '*.mjs' '*.cjs' '*.mts' '*.cts')
scan_re='readdirSync|readdir\(|opendirSync|globSync|globby|fast-glob|tinyglobby|new Glob\(|import\.meta\.glob|walkSync|git ls-files'
scanning_tests() {
  scanners=$(git -c core.quotePath=false grep -lE --untracked -e "$scan_re" -- "${native_globs[@]}" 2>/dev/null)
  {
    printf '%s\n' "$scanners" | while IFS= read -r s; do
      [ -n "$s" ] || continue
      if is_test_file "$s"; then
        printf '%s\n' "$s"
        continue
      fi
      case "/$s" in
        */__tests__/* | */test/* | */tests/* | */test-utils/* | */testutils/* | */spec/*) ;;
        *) continue ;;
      esac
      stem=$(basename "$s")
      stem="${stem%.*}"
      [ "${#stem}" -ge 4 ] || continue
      git -c core.quotePath=false grep -lF --untracked -e "$stem" -- "${native_globs[@]}" 2>/dev/null \
        | while IFS= read -r t; do is_test_file "$t" && printf '%s\n' "$t"; done
    done
  } | sort -u
}

selected=""
native=""
first_new_native=""
while IFS= read -r f; do
  [ -n "$f" ] || continue
  if reason=$(is_trigger "$f"); then full "$reason"; fi
  if printf '%s\n' "$added_files" | grep -qxF -- "$f" \
    && ! is_test_file "$f" && ! is_snapshot "$f" && ! is_inert "$f"; then
    # A new JS/TS file stays scoped: its runner maps the import graph, and the
    # directory-scanning tests are added below. Other new files still go full.
    is_native "$f" || full "new file can reach tests that scan its directory: $f"
    [ -n "$first_new_native" ] || first_new_native="$f"
  fi

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

scoped_reason="no escalation trigger matched"
if [ -n "$first_new_native" ]; then
  scans=$(scanning_tests)
  # Finding none means none exist or the search cannot see how they list
  # files; either way only the full suite is known to reach the new file.
  [ -n "$scans" ] || full "new file and no directory-scanning test found to cover it: $first_new_native"
  native="$native
$scans"
  scoped_reason="new file: related tests plus $(printf '%s\n' "$scans" | grep -c .) directory-scanning tests"
fi

echo "mode=scoped"
echo "reason=$scoped_reason"
echo "base=$base"
printf '%s\n' "$changed_files" | sed 's/^/file=/'
printf '%s\n' "$native" | grep -v '^$' | sort -u | sed 's/^/native=/'
printf '%s\n' "$selected" | grep -v '^$' | sed 's/^/test=/'
echo "selected=$n total=$total"
