#!/usr/bin/env bash
# Regression tests for hooks/post-edit-typecheck.sh.
# Run: bash post-edit-typecheck.test.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="$SCRIPT_DIR/../hooks/post-edit-typecheck.sh"

pass=0
fail=0

run_case() { # run_case <name> <expected-exit> <file-path>
  local name="$1" expected="$2" file="$3" got
  jq -n --arg f "$file" '{tool_input:{file_path:$f}}' | bash "$SUT" >/dev/null 2>&1
  got=$?
  if [ "$got" = "$expected" ]; then
    echo "PASS: $name (exit $got)"
    pass=$((pass + 1))
  else
    echo "FAIL: $name — expected exit $expected, got $got"
    fail=$((fail + 1))
  fi
}

# Fixture: package whose typecheck script fails.
bad=$(mktemp -d)
mkdir -p "$bad/src"
printf '{"name":"bad","scripts":{"typecheck":"exit 1"}}' > "$bad/package.json"
touch "$bad/package-lock.json"
touch "$bad/src/a.ts"

# Fixture: package whose typecheck script passes (no lint script).
good=$(mktemp -d)
mkdir -p "$good/src"
printf '{"name":"good","scripts":{"typecheck":"exit 0"}}' > "$good/package.json"
touch "$good/package-lock.json"
touch "$good/src/a.ts"

run_case "failing typecheck blocks" 2 "$bad/src/a.ts"
run_case "passing typecheck allows" 0 "$good/src/a.ts"
run_case "non-TS file ignored" 0 "$bad/src/readme.md"

# Bypass env var must skip the check entirely.
jq -n --arg f "$bad/src/a.ts" '{tool_input:{file_path:$f}}' \
  | SKIP_POST_EDIT_TYPECHECK=1 bash "$SUT" >/dev/null 2>&1
if [ $? -eq 0 ]; then
  echo "PASS: bypass env skips the check (exit 0)"
  pass=$((pass + 1))
else
  echo "FAIL: bypass env skips the check — expected exit 0"
  fail=$((fail + 1))
fi

rm -rf "$bad" "$good"

echo ""
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
