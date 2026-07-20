#!/usr/bin/env bash
# PreToolUse (Bash, git push): fallback quality gate. A fresh /verify-done
# READY marker in the pushed checkout is trusted as-is; without one, run every
# quality script the project defines (lint, typecheck, test, build - in that
# order) and block on the first failure.
# Bypass: set SKIP_PUSH_GATE to any non-empty value.

set -u

[ -n "${SKIP_PUSH_GATE:-}" ] && exit 0
command -v jq >/dev/null 2>&1 || exit 0

payload=$(cat 2>/dev/null) || exit 0
[ -n "$payload" ] || exit 0

cmd=$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null) || exit 0
# Match both `git push …` and `git -C <path> push …` — the -C form has no
# literal "git push" substring and would otherwise bypass the gate.
printf '%s\n' "$cmd" | grep -Eq "git[[:space:]]+(-C[[:space:]]+(\"[^\"]*\"|'[^']*'|[^[:space:]]+)[[:space:]]+)?push([[:space:]]|\$)" || exit 0

# Resolve the repo the push actually targets (same approach as the other
# push gates): `git -C <path>` or a leading `cd <path> &&` wins over the cwd.
target=""
target=$(printf '%s\n' "$cmd" | sed -n 's/.*git -C[[:space:]]\{1,\}"\([^"]*\)".*/\1/p' | head -1)
[ -n "$target" ] || target=$(printf '%s\n' "$cmd" | sed -n "s/.*git -C[[:space:]]\{1,\}'\([^']*\)'.*/\1/p" | head -1)
[ -n "$target" ] || target=$(printf '%s\n' "$cmd" | sed -n 's/.*git -C[[:space:]]\{1,\}\([^"'"'"'[:space:]][^[:space:]]*\).*/\1/p' | head -1)
[ -n "$target" ] || target=$(printf '%s\n' "$cmd" | sed -n '1s/^cd[[:space:]]\{1,\}"\([^"]*\)"[[:space:]]*&&.*/\1/p')
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

# A fresh /verify-done READY marker already certifies these exact checks in
# the checkout being pushed — verify-done runs what CI runs, any edit deletes
# the marker, and the verify gate enforces its presence. Re-running the suite
# here would double every push's wall-clock cost, possibly in a different
# checkout than the one verified. Trust the marker; the suite below stays as
# the fallback when none exists.
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

for step in lint typecheck test build; do
  jq -e --arg n "$step" '.scripts[$n]' "$pkg_dir/package.json" >/dev/null 2>&1 || continue
  out=$(cd "$pkg_dir" && CI=true $pm run "$step" 2>&1)
  if [ $? -ne 0 ]; then
    "$(dirname "$0")/record-gate-block.sh" "pre-push-gate" "$payload" 2>/dev/null || true
    {
      echo "Push blocked: '$step' failed."
      echo "Command: CI=true $pm run $step (run in $pkg_dir)"
      echo ""
      printf '%s\n' "$out" | tail -n 40
      echo ""
      echo "Fix the failures above before pushing."
      echo "Prefer /verify-done: a READY verdict records a marker this gate trusts, so the suite is not re-run at push time."
      echo "Bypass (human-only): '!'-prefix the command, or export SKIP_PUSH_GATE=1 in your shell."
    } >&2
    exit 2
  fi
done

exit 0
