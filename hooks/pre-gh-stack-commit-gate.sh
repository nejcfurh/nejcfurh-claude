#!/usr/bin/env bash
# PreToolUse (Bash, via gh-gate-dispatch.sh): refuse to let `gh stack` create the
# commit.
#
# `gh stack init` and `gh stack add` accept -A/--all and -m to stage and commit in
# one step. That commit never reaches the commit gates: git-gate-dispatch.sh routes
# on the substring `commit`, which this command line does not contain, so the
# branch, co-author, conventional-message and secret gates all sit out a real
# commit. Any repo-side commit-msg hook is skipped for the same reason.
#
# The split is the fix: `gh stack` owns branch topology, `git commit` owns content.
# Staging and committing separately costs one extra command and puts the commit
# back under every gate.
#
# Bypass: set SKIP_GH_STACK_COMMIT_GATE to any non-empty value.

set -u

[ -n "${SKIP_GH_STACK_COMMIT_GATE:-}" ] && exit 0

payload=$(cat 2>/dev/null) || exit 0
[ -n "$payload" ] || exit 0

command -v jq >/dev/null 2>&1 || exit 0

cmd=$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null) || exit 0
[ -n "$cmd" ] || exit 0

case "$cmd" in
  *"gh "*) : ;;
  *) exit 0 ;;
esac

# A here-document body is data, not commands. Without this a commit message that
# merely describes this gate trips it — which is how the gate first fired.
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

# Then blank quoted spans: a subject is free text and may contain anything,
# including something flag-shaped or the name of this very command.
scrubbed=$(printf '%s' "$scrubbed" | sed -e "s/'[^']*'/''/g" -e 's/"[^"]*"/""/g')

# Split on shell separators so `gh stack` has to START a command rather than
# appear anywhere in a longer script. awk, not sed: BSD sed does not expand \n
# in a replacement.
target=$(printf '%s' "$scrubbed" \
  | awk '{ gsub(/&&|\|\||;|\|/, "\n"); print }' \
  | grep -E '^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*gh[[:space:]]+stack[[:space:]]+(init|add|amend)([[:space:]]|$)')
[ -n "$target" ] || exit 0

# -m/--message is the whole hole: it is the only flag that creates a commit.
# -A/--all and -u/--update merely stage, and the `git commit` that must follow
# them is gated like any other, so blocking those would be friction with no
# safety return. A short bundle containing `m` is -m: this command's only other
# short flags are A, u and h. Scanned on the matched command alone, so a -m
# belonging to a different command in the same line is not attributed here.
printf '%s\n' "$target" | grep -Eq -- '(^|[[:space:]])(-[a-zA-Z]*m[a-zA-Z]*|--message)([[:space:]]|=|$)' || exit 0

HELPER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/record-gate-block.sh"
[ -x "$HELPER" ] && "$HELPER" gh-stack-commit "$payload" >/dev/null 2>&1

cat >&2 <<'MSG'
BLOCKED: `gh stack` must not create the commit.

A commit made through `gh stack init|add` with -A/--all or -m never reaches the
commit gates — the dispatcher routes on the substring `commit`, which this command
line does not contain — so the branch, co-author, conventional-message and secret
gates are all skipped, along with any repo commit-msg hook.

Split it. Topology from gh, content from git:

  gh stack add <branch-name>
  git add <paths>
  git commit -m "<subject>"

Then check `git diff --cached --stat` before the commit, as on any other commit.
MSG

exit 2
