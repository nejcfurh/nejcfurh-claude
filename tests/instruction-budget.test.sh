#!/usr/bin/env bash
# Keeps CLAUDE.md + rules/*.md under a character budget. Claude Code warns
# when the instruction files it loads exceed a total (120k chars on a 200k
# context window, ~155k on 1M), and a project's own CLAUDE.md counts toward
# that total too — so the user-level files stay well below it. A rule edit
# that goes over makes room for itself by tightening something else.
# Chars are counted as Claude Code counts them: JavaScript string length
# (two-byte code units), not bytes.
# Run: bash instruction-budget.test.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
BUDGET=${INSTRUCTION_BUDGET:-120000}

command -v python3 >/dev/null 2>&1 || { echo "FAIL: python3 is required to count instruction chars"; exit 1; }

count() { # count <file>... -> total JavaScript string length
  python3 -c 'import sys; print(sum(len(open(f, encoding="utf-8").read().encode("utf-16-le")) // 2 for f in sys.argv[1:]))' "$@"
}

fail=0

# The counter itself: an em dash is one unit, an emoji two, as in JavaScript.
probe=$(mktemp "${TMPDIR:-/tmp}/budget.XXXXXX") || exit 1
printf 'a\xe2\x80\x94\xf0\x9f\x99\x82' >"$probe"
got=$(count "$probe")
rm -f "$probe"
if [ "$got" != 4 ]; then echo "FAIL: counter measured $got units for 'a—🙂', expected 4"; fail=1; fi

files=("$REPO/CLAUDE.md" "$REPO"/rules/*.md)
total=$(count "${files[@]}")
if [ "$total" -gt "$BUDGET" ]; then
  echo "FAIL: CLAUDE.md + rules/ = $total chars, over the $BUDGET budget by $((total - BUDGET))."
  echo "      Largest files:"
  for f in "${files[@]}"; do printf '%8d  %s\n' "$(count "$f")" "${f#"$REPO"/}"; done | sort -rn | head -3
  fail=1
else
  echo "PASS: CLAUDE.md + rules/ = $total chars ($((BUDGET - total)) under the $BUDGET budget)"
fi

exit $fail
