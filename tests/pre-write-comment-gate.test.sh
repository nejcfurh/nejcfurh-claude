#!/usr/bin/env bash
# Regression tests for hooks/pre-write-comment-gate.sh — blocks a prose code
# comment when the target repo's own CLAUDE.md prohibits comments.
#
# The load-bearing cases here are the ALLOWS. A gate on every Write and Edit of
# every source file is in the way of all normal work, so a false positive is far
# more expensive than a miss: repos with no such rule, edits that carry an
# existing comment along unchanged, whole-file rewrites of a file that already
# has comments, and the pragmas that have no choice but to be comments all have
# to stay silent.
#
# Fixtures are throwaway git repos, never this one and never any real checkout —
# the prohibition is read from a CLAUDE.md the test writes itself, so the suite
# asserts the mechanism rather than whatever any project on the machine happens
# to say. One fixture puts the prohibition in an ancestor OUTSIDE the repo, which
# must not govern files inside it.
# Run: bash pre-write-comment-gate.test.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="$SCRIPT_DIR/../hooks/pre-write-comment-gate.sh"

pass=0
fail=0

command -v jq >/dev/null 2>&1 || {
  echo "SKIP: jq is required to build payloads"
  exit 0
}

# pwd -P everywhere: the gate resolves both ends physically, and on macOS an
# unresolved TMPDIR would not compare equal to git's resolved toplevel.
mkrepo() {
  local d
  d=$(mktemp -d "${TMPDIR:-/tmp}/hooktest-comment.XXXXXX") || return 1
  d=$(cd "$d" && pwd -P) || return 1
  git -C "$d" init -q 2>/dev/null || return 1
  mkdir -p "$d/src" || return 1
  printf 'export const a = 1;\n' > "$d/src/plain.ts"
  printf '// established comment\nexport const b = 2;\n' > "$d/src/commented.ts"
  printf '%s' "$d"
}

BANNED=$(mkrepo) || exit 1
printf '# Rules\n\n- **Do not comment code. This is a hard rule.** Write zero comments by default.\n' \
  > "$BANNED/CLAUDE.md"

ALLOWED=$(mkrepo) || exit 1
printf '# Rules\n\n- Comment a non-obvious WHY. No comments needed for obvious code.\n' \
  > "$ALLOWED/CLAUDE.md"

SILENT=$(mkrepo) || exit 1

# The prohibition lives one level ABOVE the repo root, so it governs nothing in it.
OUTER=$(mktemp -d "${TMPDIR:-/tmp}/hooktest-outer.XXXXXX") || exit 1
OUTER=$(cd "$OUTER" && pwd -P) || exit 1
printf '# Rules\n\n- Do not comment code.\n' > "$OUTER/CLAUDE.md"
NESTED="$OUTER/inner"
mkdir -p "$NESTED/src" || exit 1
git -C "$NESTED" init -q 2>/dev/null || exit 1
printf 'export const a = 1;\n' > "$NESTED/src/plain.ts"

trap 'rm -rf "$BANNED" "$ALLOWED" "$SILENT" "$OUTER"' EXIT

edit() {
  jq -n --arg fp "$1" --arg old "$2" --arg new "$3" \
    '{tool_input:{file_path:$fp,old_string:$old,new_string:$new}}'
}

write_call() {
  jq -n --arg fp "$1" --arg c "$2" '{tool_input:{file_path:$fp,content:$c}}'
}

# blocks <name> <payload> — expects exit 2 and an explanation on stderr
blocks() {
  local name="$1" payload="$2" out rc
  out=$(printf '%s' "$payload" | bash "$SUT" 2>&1)
  rc=$?
  if [ "$rc" = "2" ] && [ -n "$out" ]; then
    echo "PASS: blocks — $name"
    pass=$((pass + 1))
  else
    echo "FAIL: blocks — $name (rc=$rc)"
    fail=$((fail + 1))
  fi
}

# allows <name> <payload> — expects exit 0 and total silence
allows() {
  local name="$1" payload="$2" out rc
  out=$(printf '%s' "$payload" | bash "$SUT" 2>&1)
  rc=$?
  if [ "$rc" = "0" ] && [ -z "$out" ]; then
    echo "PASS: allows — $name"
    pass=$((pass + 1))
  else
    echo "FAIL: allows — $name (rc=$rc, output: ${out:-none})"
    fail=$((fail + 1))
  fi
}

# --- blocks: a new prose comment in a repo that prohibits them -----------------
blocks "line comment added by an Edit" \
  "$(edit "$BANNED/src/plain.ts" 'export const a = 1;' '// why this exists
export const a = 1;')"

blocks "block comment added by an Edit" \
  "$(edit "$BANNED/src/plain.ts" 'export const a = 1;' '/* rationale */
export const a = 1;')"

blocks "JSX comment in a tsx file" \
  "$(edit "$BANNED/src/Comp.tsx" '<div />' '{/* spacing hack */}
<div />')"

blocks "comment in a brand new file" \
  "$(write_call "$BANNED/src/does-not-exist-yet.ts" '// header
export const a = 1;')"

blocks "whole-file rewrite that adds one comment" \
  "$(write_call "$BANNED/src/commented.ts" '// established comment
// newly added
export const b = 2;')"

blocks "comment several lines into the new_string" \
  "$(edit "$BANNED/src/plain.ts" 'const a = 1;' 'const a = 1;
const b = 2;
// explains b
const c = 3;')"

# --- allows: no prohibition to enforce ----------------------------------------
allows "repo whose CLAUDE.md only prefers fewer comments" \
  "$(edit "$ALLOWED/src/plain.ts" 'export const a = 1;' '// legitimate why
export const a = 1;')"

allows "repo with no CLAUDE.md at all" \
  "$(edit "$SILENT/src/plain.ts" 'export const a = 1;' '// legitimate why
export const a = 1;')"

allows "prohibition in an ancestor outside the repo" \
  "$(edit "$NESTED/src/plain.ts" 'export const a = 1;' '// legitimate why
export const a = 1;')"

# --- allows: nothing new was added --------------------------------------------
allows "existing comment carried along unchanged" \
  "$(edit "$BANNED/src/plain.ts" '// keep me
const a = 1;' '// keep me
const a = 2;')"

allows "existing comment re-indented" \
  "$(edit "$BANNED/src/plain.ts" '// keep me
const a=1;' '  // keep me
  const a = 1;')"

allows "whole-file rewrite that keeps its comments" \
  "$(write_call "$BANNED/src/commented.ts" "$(cat "$BANNED/src/commented.ts")")"

allows "comment removed rather than added" \
  "$(edit "$BANNED/src/commented.ts" '// established comment
export const b = 2;' 'export const b = 2;')"

# --- allows: directives have to be comments -----------------------------------
allows "ts-expect-error" \
  "$(edit "$BANNED/src/plain.ts" 'const a = 1;' '// @ts-expect-error narrowing
const a = 1;')"

allows "eslint-disable-next-line" \
  "$(edit "$BANNED/src/plain.ts" 'const a = 1;' '// eslint-disable-next-line no-console
const a = 1;')"

# Named after the shape, not the tool: the exemption is <tool>-disable/-enable/
# -ignore, so a linter nobody has heard of is exempt on the same terms.
allows "an unfamiliar linter's disable pragma" \
  "$(edit "$BANNED/src/plain.ts" 'const a = 1;' '// somelinter-disable-next-line no-console
const a = 1;')"

allows "an ignore-shaped pragma" \
  "$(edit "$BANNED/src/plain.ts" 'const a = 1;' '// someformatter-ignore
const a = 1;')"

allows "a block-comment disable pragma" \
  "$(edit "$BANNED/src/plain.ts" 'const a = 1;' '/* somelinter-disable no-console */
const a = 1;')"

allows "istanbul-style coverage pragma" \
  "$(edit "$BANNED/src/plain.ts" 'const a = 1;' '/* istanbul ignore next */
const a = 1;')"

allows "triple-slash reference" \
  "$(edit "$BANNED/src/plain.ts" 'const a = 1;' '/// <reference types="node" />
const a = 1;')"

allows "webpack magic comment" \
  "$(edit "$BANNED/src/plain.ts" 'const a = 1;' '/* webpackChunkName: "x" */
const a = 1;')"

allows "shebang" \
  "$(write_call "$BANNED/src/cli-new.ts" '#!/usr/bin/env node
export const a = 1;')"

# --- allows: not a comment, and not a source file -----------------------------
allows "url containing a double slash" \
  "$(edit "$BANNED/src/plain.ts" 'const a = 1;' "const u = 'https://example.test';")"

allows "markdown file" \
  "$(edit "$BANNED/README.md" 'a' '// b')"

allows "the repo CLAUDE.md itself" \
  "$(edit "$BANNED/CLAUDE.md" 'a' '// b')"

# --- bypass -------------------------------------------------------------------
# Piped straight from jq: the gate returns before reading stdin here, and jq
# absorbs the EPIPE that a printf would report as a spurious failure.
out=$(edit "$BANNED/src/plain.ts" 'const a = 1;' '// why
const a = 1;' | SKIP_COMMENT_PROHIBITION_GATE=1 bash "$SUT" 2>&1)
rc=$?
if [ "$rc" = "0" ] && [ -z "$out" ]; then
  echo "PASS: allows — SKIP env silences the gate"
  pass=$((pass + 1))
else
  echo "FAIL: allows — SKIP env silences the gate (rc=$rc)"
  fail=$((fail + 1))
fi

# --- malformed input fails open -----------------------------------------------
allows "empty payload" ''
allows "payload with no file_path" '{"tool_input":{"new_string":"// x"}}'

echo
echo "passed: $pass, failed: $fail"
[ "$fail" -eq 0 ] || exit 1
