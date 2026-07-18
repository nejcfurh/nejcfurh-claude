#!/usr/bin/env bash
# PreToolUse (Bash, gh): block PR merges — the user merges PRs manually.
# Catches `gh pr merge` anywhere in the command (compound forms included) and
# the API fallback `gh api … pulls/<n>/merge`. Permission-rule globs only
# catch the literal prefix `gh pr merge …`.
# Bypass: set SKIP_MERGE_GATE to any non-empty value.

set -u

[ -n "${SKIP_MERGE_GATE:-}" ] && exit 0
command -v jq >/dev/null 2>&1 || exit 0

payload=$(cat 2>/dev/null) || exit 0
[ -n "$payload" ] || exit 0

cmd=$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null) || exit 0

# Strip heredoc bodies and quoted spans before matching — 'gh pr merge'
# inside a PR body or commit message is prose, not a merge. Heredocs go
# first (they are line-based); then newlines are collapsed so multi-line
# quoted arguments strip as one span.
stripped=$(printf '%s\n' "$cmd" | awk '
  inhd { if ($0 == mark) inhd = 0; next }
  match($0, /<<-?[[:space:]]*["'\'']?[A-Za-z_][A-Za-z_0-9]*/) {
    mark = substr($0, RSTART, RLENGTH)
    sub(/<<-?[[:space:]]*["'\'']?/, "", mark)
    inhd = 1
    print
    next
  }
  { print }
')
stripped=$(printf '%s' "$stripped" | tr '\n' ' ' | sed -e "s/'[^']*'//g" -e 's/"[^"]*"//g')

if ! printf '%s\n' "$stripped" | grep -Eq "gh[[:space:]]+pr[[:space:]]+merge([[:space:]]|\$)"; then
  printf '%s\n' "$stripped" | grep -Eq "gh[[:space:]]+api[[:space:]][^;|&]*pulls/[^[:space:]/]+/merge" || exit 0
fi

"$(dirname "$0")/record-gate-block.sh" "pre-merge-gate" "$payload" 2>/dev/null || true
{
  echo "Blocked: merging PRs is reserved for the user — never merge on their behalf."
  echo "Hand them the exact command to run instead (with the '!' prefix in the prompt)."
  echo "Bypass (human-only): '!'-prefix the command, or export SKIP_MERGE_GATE=1 in your shell."
} >&2
exit 2
