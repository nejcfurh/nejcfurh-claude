#!/usr/bin/env bash
# PreToolUse (Bash, gh pr create): fallback quality gate before a PR is
# opened. A fresh /verify-done READY marker in the target checkout is trusted
# as-is (verify-done already ran the exact CI checks, tests included);
# without one, run the project's test script and block (exit 2) on failure.
# Bypass: set SKIP_PR_TEST_GATE to any non-empty value.

set -u

[ -n "${SKIP_PR_TEST_GATE:-}" ] && exit 0
command -v jq >/dev/null 2>&1 || exit 0

payload=$(cat 2>/dev/null) || exit 0
[ -n "$payload" ] || exit 0

cmd=$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null) || exit 0
case "$cmd" in
  *"gh pr create"*) : ;;
  *) exit 0 ;;
esac

# This hook is wired directly (not through the git dispatcher), so nothing
# has moved us to the checkout the Bash tool is in — the payload's cwd is
# the only signal. Without this, worktree flows test the wrong tree.
payload_cwd=$(printf '%s' "$payload" | jq -r '.cwd // empty' 2>/dev/null)
if [ -n "$payload_cwd" ] && [ -d "$payload_cwd" ]; then
  cd "$payload_cwd" 2>/dev/null || true
fi

# A leading `cd <path> &&` names the target checkout explicitly and wins
# over the cwd (same approach as the push gates; gh has no -C flag).
target=""
target=$(printf '%s\n' "$cmd" | sed -n '1s/^cd[[:space:]]\{1,\}"\([^"]*\)"[[:space:]]*&&.*/\1/p')
[ -n "$target" ] || target=$(printf '%s\n' "$cmd" | sed -n "1s/^cd[[:space:]]\{1,\}'\([^']*\)'[[:space:]]*&&.*/\1/p")
[ -n "$target" ] || target=$(printf '%s\n' "$cmd" | sed -n '1s/^cd[[:space:]]\{1,\}\([^[:space:]]*\)[[:space:]]*&&.*/\1/p')
case "$target" in *'$'*) target="" ;; esac

repo=""
for cand in "$target" "$PWD" "${CLAUDE_PROJECT_DIR:-}"; do
  [ -n "$cand" ] || continue
  [ -d "$cand" ] || continue
  if git -C "$cand" rev-parse --show-toplevel >/dev/null 2>&1; then
    repo="$cand"
    break
  fi
done

# A fresh /verify-done READY marker already certifies the tests (and more) in
# this checkout — the push that preceded this PR required it, and any edit
# since would have deleted it. Re-running the suite here would double the
# cost of every PR. The run below stays as the fallback when none exists.
if [ -n "$repo" ]; then
  git_dir=$(git -C "$repo" rev-parse --absolute-git-dir 2>/dev/null)
  ttl="${VERIFY_DONE_TTL_MINUTES:-120}"
  if [ -n "$git_dir" ] && [ -f "$git_dir/verify-done-ok" ] \
    && [ -n "$(find "$git_dir/verify-done-ok" -mmin -"$ttl" 2>/dev/null)" ]; then
    exit 0
  fi
fi

# Nearest package.json walking up (stop at $HOME or /), from the resolved
# repo, then $PWD, then $CLAUDE_PROJECT_DIR.
find_pkg_dir() {
  d="$1"
  while :; do
    if [ -f "$d/package.json" ]; then printf '%s\n' "$d"; return 0; fi
    [ "$d" = "/" ] && break
    [ "$d" = "$HOME" ] && break
    d=$(dirname "$d")
  done
  return 1
}

pkg_dir=""
for cand in "$repo" "$PWD" "${CLAUDE_PROJECT_DIR:-}"; do
  [ -n "$cand" ] || continue
  [ -d "$cand" ] || continue
  if pkg_dir=$(find_pkg_dir "$cand"); then break; fi
  pkg_dir=""
done
[ -n "$pkg_dir" ] || exit 0

# No test script, or only the npm placeholder -> nothing to gate on.
test_script=$(jq -r '.scripts.test // ""' "$pkg_dir/package.json" 2>/dev/null)
[ -n "$test_script" ] || exit 0
case "$test_script" in
  *"no test specified"*) exit 0 ;;
esac

# Package manager from the nearest lockfile, walking up (stop at $HOME or /).
pm="npm"
d="$pkg_dir"
while :; do
  if [ -f "$d/bun.lock" ] || [ -f "$d/bun.lockb" ]; then pm="bun"; break; fi
  if [ -f "$d/pnpm-lock.yaml" ]; then pm="pnpm"; break; fi
  if [ -f "$d/yarn.lock" ]; then pm="yarn"; break; fi
  [ "$d" = "/" ] && break
  [ "$d" = "$HOME" ] && break
  d=$(dirname "$d")
done

out=$(cd "$pkg_dir" && CI=true $pm run test 2>&1)
if [ $? -ne 0 ]; then
  "$(dirname "$0")/record-gate-block.sh" "pre-pr-test-gate" "$payload" 2>/dev/null || true
  {
    echo "Blocked: tests must pass before opening a PR."
    echo "Command: CI=true $pm run test (run in $pkg_dir)"
    echo ""
    printf '%s\n' "$out" | tail -n 40
    echo ""
    echo "Fix the failing tests, then create the PR again."
    echo "Prefer /verify-done: a READY verdict records a marker this gate trusts, so tests are not re-run here."
    echo "Bypass (human-only): '!'-prefix the command, or export SKIP_PR_TEST_GATE=1 in your shell."
  } >&2
  exit 2
fi

exit 0
