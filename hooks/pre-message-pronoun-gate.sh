#!/usr/bin/env bash
# PreToolUse: warn when text about to be published uses a gendered pronoun.
#
# Two entry points:
#   - Bash, `gh pr|issue create|edit|comment|review` and `gh api`: scans the
#     command and any body file it names (--body-file, -F body=@file).
#   - A tool that sends or saves a message, ticket or comment: scans every
#     string in its input.
#
# A pronoun guessed from a name misgenders a real person, and a "she" or "he"
# for a generic user reads as an assumption about who the users are. Both land
# in PR bodies and tickets, where they outlive the session and nobody re-reads
# them. They/them is the default unless the person's pronouns were stated.
#
# Warn-only: a quoted message or a stated pronoun is legitimate, so the call
# goes through and the model decides.
#
# Bypass: set SKIP_PRONOUN_GATE to any non-empty value.

set -u

[ -n "${SKIP_PRONOUN_GATE:-}" ] && exit 0

payload=$(cat 2>/dev/null) || exit 0
[ -n "$payload" ] || exit 0

command -v jq >/dev/null 2>&1 || exit 0
command -v perl >/dev/null 2>&1 || exit 0

tool=$(printf '%s' "$payload" | jq -r '.tool_name // empty' 2>/dev/null) || exit 0

if [ "$tool" = "Bash" ]; then
  cmd=$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null) || exit 0
  printf '%s' "$cmd" | grep -Eq 'gh[[:space:]]+((pr|issue)[[:space:]]+(create|edit|comment|review)|api)([[:space:]]|$)' || exit 0

  payload_cwd=$(printf '%s' "$payload" | jq -r '.cwd // empty' 2>/dev/null)
  if [ -n "$payload_cwd" ] && [ -d "$payload_cwd" ]; then
    cd "$payload_cwd" 2>/dev/null || true
  fi

  text=$cmd
  files=$(printf '%s' "$cmd" | perl -ne '
    while (/--body-file(?:=|\s+)(["\x27]?)(\S+?)\1(?=\s|$)/g) { print "$2\n" }
    while (/(?:-F|--field|-f|--raw-field)\s+(["\x27]?)body=@(\S+?)\1(?=\s|$)/g) { print "$2\n" }
  ' 2>/dev/null)
  while IFS= read -r f; do
    [ -n "$f" ] && [ -f "$f" ] && text="$text
$(cat "$f" 2>/dev/null)"
  done <<EOF
$files
EOF
else
  text=$(printf '%s' "$payload" | jq -r '[.tool_input | .. | strings] | join("\n")' 2>/dev/null) || exit 0
fi
[ -n "$text" ] || exit 0

words=$(printf '%s' "$text" | perl -CSD -ne '
  while (/\b(she|her|hers|herself|he|him|his|himself)\b/gi) { print lc($1), "\n" }
' 2>/dev/null | sort -u | tr '\n' ' ' | sed 's/ $//')
[ -n "$words" ] || exit 0

# shellcheck source=hooks/hook-output-lib.sh
. "$(dirname "$0")/hook-output-lib.sh"

hook_warn PreToolUse <<EOF
[pronoun] This text uses gendered pronouns: $words.
Use one only where the person stated it or where you quote someone's own
words. A name says nothing about pronouns, and a generic user, member or
shopper is "they". If any of these is a guess, rewrite it before it publishes.
EOF
exit 0
