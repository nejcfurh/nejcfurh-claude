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

# A rule with `paths:` frontmatter loads only when a matching file is read,
# not at startup, so it is left out of the startup budget.
scoped() { # scoped <file> -> exit 0 if its frontmatter has a paths: key
  awk 'NR == 1 { if ($0 != "---") exit 1; next } /^---$/ { exit 1 } /^paths:/ { found = 1; exit 0 } END { exit !found }' "$1"
}

# The detector itself: frontmatter paths counts, a body line does not.
probe_dir=$(mktemp -d "${TMPDIR:-/tmp}/budget-scope.XXXXXX") || exit 1
printf -- '---\npaths:\n  - "**/*.ts"\n---\n# x\n' >"$probe_dir/scoped.md"
printf -- '# x\npaths: not frontmatter\n' >"$probe_dir/plain.md"
printf -- '---\nname: x\n---\npaths: after frontmatter\n' >"$probe_dir/other.md"
scoped "$probe_dir/scoped.md" || { echo "FAIL: detector missed paths: frontmatter"; fail=1; }
if scoped "$probe_dir/plain.md"; then echo "FAIL: detector took a body line for frontmatter"; fail=1; fi
if scoped "$probe_dir/other.md"; then echo "FAIL: detector read past the frontmatter"; fail=1; fi
rm -rf "$probe_dir"

files=("$REPO/CLAUDE.md")
skipped=()
for f in "$REPO"/rules/*.md; do
  if scoped "$f"; then skipped+=("${f#"$REPO"/}"); else files+=("$f"); fi
done
[ ${#skipped[@]} -gt 0 ] && echo "INFO: path-scoped, not counted: ${skipped[*]}"
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
