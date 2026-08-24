#!/usr/bin/env bash
# PreToolUse (Bash): warn when a command whose exit status is load-bearing is
# piped into a pager-ish filter, so the reported status belongs to the filter.
#
# `cmd | tail -5` exits with tail's status, which is 0 almost always. Pair that
# with an `echo "exit:$?"` and you get a check that reports success no matter how
# `cmd` failed — the most expensive kind of green, because it gets believed and
# built on. A --quiet/--silent flag on the left makes it worse by removing the
# error text that would have given it away.
#
# Deliberately narrow. It fires only when the LEFT side is a command whose
# failure matters (build, test, typecheck, install, migration, db client) and the
# right side swallows it. Inspection pipelines — `git log | head`, `grep x | head`,
# `ls | tail` — are the common case and are left alone; a gate that fires on
# those is noise, and noise is how a warning stops being read.
#
# Non-blocking by design: sometimes you want both the tail and the status, and
# the fix is to add the status capture rather than to not run the command.
#
# Bypass: set SKIP_BASH_PIPE_STATUS_GATE to any non-empty value.

set -u

[ -n "${SKIP_BASH_PIPE_STATUS_GATE:-}" ] && exit 0

payload=$(cat 2>/dev/null) || exit 0
[ -n "$payload" ] || exit 0

# This runs on EVERY Bash call, so bail before spending a jq and two greps on the
# common case. A command with no pipe can never match, and the check is a builtin
# against the raw payload — free next to the three processes it skips.
case "$payload" in
  *'|'*) : ;;
  *) exit 0 ;;
esac

command -v jq >/dev/null 2>&1 || exit 0

cmd=$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null) || exit 0
[ -n "$cmd" ] || exit 0

# Already handling the status correctly — nothing to say.
case "$cmd" in
  *pipefail*|*PIPESTATUS*) exit 0 ;;
esac

# Must contain a pipe into a truncating/filtering consumer.
printf '%s' "$cmd" | grep -Eq '\|[[:space:]]*(tail|head|grep|wc|sed -n|awk)' || exit 0

# Left side must be a command whose exit status is the point of running it.
printf '%s' "$cmd" | grep -Eq \
  '(npm (run|ci|install|test)|npx (tsc|vitest|playwright|dbmate)|yarn (run|test)|pnpm (run|test)|vitest|jest|tsc|eslint|oxlint|oxfmt|playwright test|pytest|cargo (build|test)|go (build|test)|make|psql|pg_dump|pg_restore|dbmate|alembic|prisma migrate)' \
  || exit 0

cat <<'EOF'
[pipe-status] This pipes a command whose exit status matters into a filter, so
$? and any "exit:$?" echo will report the FILTER's status, not the command's.
Capture it instead — `cmd > out.log 2>&1; echo "exit=$?"` then read out.log, or
prefix with `set -o pipefail`. Confirm the outcome from the artifact the command
was supposed to produce, not from a status read through a pipe.
EOF
exit 0
