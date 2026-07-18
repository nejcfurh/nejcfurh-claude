#!/usr/bin/env bash
# PreToolUse (Bash, git commit): enforce Conventional Commits on the subject line.
# Never blocks when the subject cannot be extracted (parse failures exit 0).
# Bypass: set SKIP_CONVENTIONAL_GATE to any non-empty value.

set -u

[ -n "${SKIP_CONVENTIONAL_GATE:-}" ] && exit 0
command -v jq >/dev/null 2>&1 || exit 0

payload=$(cat 2>/dev/null) || exit 0
[ -n "$payload" ] || exit 0

cmd=$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null) || exit 0
# Match both `git commit …` and `git -C <path> commit …` — the -C form has no
# literal "git commit" substring and would otherwise bypass the gate.
if ! printf '%s\n' "$cmd" | grep -Eq "git[[:space:]]+-C[[:space:]]+(\"[^\"]*\"|'[^']*'|[^[:space:]]+)[[:space:]]+commit([[:space:]]|\$)"; then
  case "$cmd" in
    *"git commit"*) : ;;
    *) exit 0 ;;
  esac
fi

# Skip commit variants that reuse or intentionally omit a message.
case "$cmd" in
  *--amend*|*--fixup*|*--squash*|*--allow-empty-message*) exit 0 ;;
esac
# -C/-c reuse a message only AFTER the commit subcommand — before it, -C is
# `git -C <path>` (directory selection) and must not skip the gate.
after_commit="${cmd#*commit}"
if printf '%s\n' "$after_commit" | grep -Eq -- '(^|[[:space:]])-[Cc]([[:space:]]|$)'; then
  exit 0
fi

# --- Extract the commit subject ----------------------------------------------
subject=""
if printf '%s\n' "$cmd" | grep -q '<<'; then
  # Heredoc message: subject is the first line after the heredoc marker.
  subject=$(printf '%s\n' "$cmd" | awk 'found { print; exit } /<</ { found = 1 }')
else
  # First line of the command that carries -m.
  mline=$(printf '%s\n' "$cmd" | grep -m1 -- '-m' 2>/dev/null)
  if [ -n "$mline" ]; then
    # Double-quoted message closed on the same line.
    subject=$(printf '%s\n' "$mline" | sed -n 's/.*-m[[:space:]]*"\([^"]*\)".*/\1/p')
    # Single-quoted message closed on the same line.
    if [ -z "$subject" ]; then
      subject=$(printf '%s\n' "$mline" | sed -n "s/.*-m[[:space:]]*'\([^']*\)'.*/\1/p")
    fi
    # Multi-line quoted message: opening quote only; take the rest of the line.
    if [ -z "$subject" ]; then
      subject=$(printf '%s\n' "$mline" | sed -n 's/.*-m[[:space:]]*["'"'"']\(.*\)$/\1/p')
    fi
  fi
fi

# Extraction failed -> never block on a parse failure.
[ -n "$subject" ] || exit 0

# Merge/revert commits produced by git itself are exempt.
case "$subject" in
  Merge*|Revert*) exit 0 ;;
esac

if printf '%s\n' "$subject" \
  | grep -Eq '^(feat|fix|refactor|perf|docs|style|test|build|ci|chore|deps|security|revert)(\([a-zA-Z0-9./_-]+\))?!?: .+'; then
  exit 0
fi

{
  echo "Blocked: commit subject does not follow Conventional Commits."
  echo ""
  echo "  Subject:  $subject"
  echo "  Expected: <type>(<optional-scope>): <description>"
  echo "  Types:    feat fix refactor perf docs style test build ci chore deps security revert"
  echo "  Example:  feat(auth): add passwordless login"
  echo ""
  echo "Bypass: set SKIP_CONVENTIONAL_GATE=1"
} >&2
exit 2
