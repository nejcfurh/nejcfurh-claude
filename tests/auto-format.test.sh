#!/usr/bin/env bash
# Regression tests for hooks/auto-format.sh.
#
# The hook's contract is that it NEVER blocks — every case asserts exit 0,
# and the skip cases additionally assert the file was left untouched.
# Run: bash auto-format.test.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# A failed mktemp must never leak this suite's git commands into the real repo.
cd "$(mktemp -d "${TMPDIR:-/tmp}/hooktest-cwd.XXXXXX")" || exit 1
SUT="$SCRIPT_DIR/../hooks/auto-format.sh"

pass=0
fail=0

run_case() { # run_case <name> <file-path>
  local name="$1" file="$2" got
  jq -n --arg f "$file" '{tool_input:{file_path:$f}}' | bash "$SUT" >/dev/null 2>&1
  got=$?
  if [ "$got" = "0" ]; then
    echo "PASS: $name (exit 0)"
    pass=$((pass + 1))
  else
    echo "FAIL: $name — expected exit 0, got $got"
    fail=$((fail + 1))
  fi
}

work=$(mktemp -d "${TMPDIR:-/tmp}/hooktest.XXXXXX")
mkdir -p "$work/node_modules/pkg" "$work/src"

badly_formatted='const   x   =   1'
printf '%s' "$badly_formatted" > "$work/package-lock.json"
printf '%s' "$badly_formatted" > "$work/node_modules/pkg/index.js"
printf '%s' "$badly_formatted" > "$work/src/no-config-here.ts"
printf '%s' "$badly_formatted" > "$work/src/file.xyz"

run_case "lockfile skipped" "$work/package-lock.json"
run_case "node_modules skipped" "$work/node_modules/pkg/index.js"
run_case "no formatter config found" "$work/src/no-config-here.ts"
run_case "unsupported extension skipped" "$work/src/file.xyz"
run_case "missing file skipped" "$work/does-not-exist.ts"

# Skip cases must leave the file content untouched.
if [ "$(cat "$work/package-lock.json")" = "$badly_formatted" ] \
   && [ "$(cat "$work/node_modules/pkg/index.js")" = "$badly_formatted" ]; then
  echo "PASS: skipped files left untouched"
  pass=$((pass + 1))
else
  echo "FAIL: skipped files left untouched — content was modified"
  fail=$((fail + 1))
fi

# Local node_modules/.bin binary is preferred over npx resolution.
proj=$(mktemp -d "${TMPDIR:-/tmp}/hooktest.XXXXXX")
mkdir -p "$proj/node_modules/.bin" "$proj/src"
printf '{}' > "$proj/.prettierrc"
{
  printf '%s\n' '#!/bin/bash'
  printf '%s\n' 'touch "$(dirname "$0")/prettier-called"'
  printf '%s\n' 'exit 0'
} > "$proj/node_modules/.bin/prettier"
chmod +x "$proj/node_modules/.bin/prettier"
printf '%s' "$badly_formatted" > "$proj/src/app.ts"

run_case "local prettier bin path exits clean" "$proj/src/app.ts"
if [ -f "$proj/node_modules/.bin/prettier-called" ]; then
  echo "PASS: local node_modules/.bin/prettier was invoked"
  pass=$((pass + 1))
else
  echo "FAIL: local node_modules/.bin/prettier was invoked — stub never ran"
  fail=$((fail + 1))
fi
rm -rf "$proj"

rm -rf "$work"

echo ""
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
