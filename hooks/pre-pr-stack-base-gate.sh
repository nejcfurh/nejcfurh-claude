#!/usr/bin/env bash
# PreToolUse (Bash, via gh-gate-dispatch.sh): refuse `gh pr create --base <B>` when
# <B> is the head branch of an open PR.
#
# A PR based on another open PR is a stack, and git-conventions.md gives stack
# topology to `gh stack`. Opening the upper PR with plain `gh pr create` builds a
# hand-made chain instead: the host does not know it is a stack, so it neither
# merges it atomically nor rebases the upper PR when the lower one lands. The rule
# alone did not stop this; the command shape does, so it is a gate.
#
# Only `gh pr create` with an explicit base is checked. Without --base, gh targets
# the default branch, which is never a stack. The lookup is one `gh pr list` call
# and the gate fails open whenever it cannot answer.
#
# Bypass (a chain that is deliberately unregistered): set SKIP_PR_STACK_BASE_GATE
# to any non-empty value.

set -u

[ -n "${SKIP_PR_STACK_BASE_GATE:-}" ] && exit 0

payload=$(cat 2>/dev/null) || exit 0
[ -n "$payload" ] || exit 0

command -v jq >/dev/null 2>&1 || exit 0

cmd=$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null) || exit 0
[ -n "$cmd" ] || exit 0

case "$cmd" in
  *"gh pr create"*) : ;;
  *) exit 0 ;;
esac

# A here-document body is data, not commands: a PR body that describes this gate
# must not trip it.
scrubbed=$(printf '%s\n' "$cmd" | awk '
  BEGIN { inhd = 0; term = "" }
  {
    if (inhd) { if ($0 == term) inhd = 0; next }
    if (match($0, /<<-?[\047"]?[A-Za-z_][A-Za-z0-9_]*[\047"]?/)) {
      m = substr($0, RSTART, RLENGTH)
      sub(/^<<-?/, "", m)
      gsub(/[\047"]/, "", m)
      term = m
      inhd = 1
    }
    print
  }
')

# Unquote the two values this gate reads (branch and repo names hold no spaces),
# then blank every other quoted span, so a title that mentions `--base x` is text.
scrubbed=$(printf '%s' "$scrubbed" \
  | sed -E -e "s/(--base|-B|--repo|-R)([= ]+)[\"']([^\"' ]+)[\"']/\1\2\3/g" \
    -e "s/'[^']*'/''/g" -e 's/"[^"]*"/""/g')

# `gh pr create` has to START a command, not appear inside a longer one.
target=$(printf '%s' "$scrubbed" \
  | awk '{ gsub(/&&|\|\||;|\|/, "\n"); print }' \
  | grep -E '^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*gh[[:space:]]+pr[[:space:]]+create([[:space:]]|$)' \
  | head -n 1)
[ -n "$target" ] || exit 0

flag_value() { # flag_value <long> <short> — value of the flag in $target, or empty
  printf '%s\n' "$target" \
    | grep -oE -- "(^|[[:space:]])($1|$2)(=|[[:space:]]+)[^[:space:]]+" \
    | head -n 1 \
    | sed -E "s/^[[:space:]]*($1|$2)(=|[[:space:]]+)//"
}

base=$(flag_value --base -B)
[ -n "$base" ] || exit 0
repo=$(flag_value --repo -R)

gh_bin="${GH_BIN:-gh}"
command -v "$gh_bin" >/dev/null 2>&1 || exit 0

set -- pr list --head "$base" --state open --json number --jq '.[0].number // empty'
[ -n "$repo" ] && set -- "$@" --repo "$repo"
pr=$("$gh_bin" "$@" 2>/dev/null) || exit 0
case "$pr" in
  '' | *[!0-9]*) exit 0 ;;
esac

HELPER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/record-gate-block.sh"
[ -x "$HELPER" ] && "$HELPER" pr-stack-base "$payload" >/dev/null 2>&1

cat >&2 <<MSG
BLOCKED: the base \`$base\` is the head branch of open PR #$pr.

A PR on top of an open PR is a stack. Opened with \`gh pr create\`, it is a
hand-made chain: the host neither merges it atomically nor rebases it when #$pr
lands. Register it with \`gh stack\` instead:

  gh stack init / gh stack add <branch>, then gh stack submit
  or, when both PRs already exist: gh stack link <bottom-pr> <top-pr>

If the chain is deliberately unregistered, re-run with SKIP_PR_STACK_BASE_GATE=1.
MSG

exit 2
