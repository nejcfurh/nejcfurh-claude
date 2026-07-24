#!/bin/sh
# POSIX sh, not bash: nothing here needs bash, and where /bin/sh is dash this
# starts measurably faster. On macOS /bin/sh IS bash 3.2, so it changes nothing
# there — measured 24.1ms via sh vs 25.6ms via bash.
#
# Cost of this filter: ~24ms, against ~4ms for the inline `jq || cat` it replaced.
# That is not a hot path. git only runs a clean filter when it has to re-hash the
# file, so the stat cache absorbs it: `git status` measured 9.4ms with this driver
# vs 10.6ms with the old one, and 10.8ms right after the mtime was bumped. The
# real cost is one ~24ms hit the first time git re-reads settings.json after
# Claude Code rewrites it. Buffering is not optional — see below.
#
# git clean filter for settings.json: strips the runtime state Claude Code
# rewrites into the file (.feedbackSurveyState and .model, which change on every
# /model) so it never surfaces as a diff. Reads the file on stdin, writes the
# cleaned version to stdout. Wired up by scripts/setup.sh; declared in
# .gitattributes.
#
# Why this is a script and not `jq … || cat` inline in git config: git feeds
# clean filters through a PIPE. jq consumes all of stdin before it fails, so an
# inline `|| cat` has nothing left to replay and emits NOTHING — git then stages
# a 0-BYTE blob and exits 0 without a warning. Invalid JSON is exactly what a
# rebase conflict or a mid-edit typo leaves in settings.json, and refreshing the
# worktree from that empty blob (branch switch, or the documented
# `git restore --source=origin/main settings.json`) wipes every permission rule
# and hook wiring — on a machine where settings.json is symlinked into
# ~/.claude, that disables the whole config silently.
#
# Invariant: non-empty input NEVER produces empty output. When the content
# cannot be cleaned, stage it exactly as it is on disk.
set -u

# No jq: pass through untouched. Checked before reading stdin so `cat` still
# has the whole input to hand over.
if ! command -v jq >/dev/null 2>&1; then
  exec cat
fi

# Buffer stdin so the fallback can replay it. A failure to allocate the buffer
# also degrades to pass-through rather than to an empty blob.
in=$(mktemp "${TMPDIR:-/tmp}/strip-ephemeral-in.XXXXXX" 2>/dev/null) || exec cat
out=$(mktemp "${TMPDIR:-/tmp}/strip-ephemeral-out.XXXXXX" 2>/dev/null) || {
  rm -f "$in"
  exec cat
}
trap 'rm -f "$in" "$out"' EXIT

cat > "$in"

# jq writes to its own file rather than straight to stdout: on malformed input
# that happens to start with a valid value, jq can emit before it fails, and
# appending the fallback to a partial write would corrupt the staged content.
if jq 'del(.feedbackSurveyState) | del(.model)' "$in" > "$out" 2>/dev/null; then
  cat "$out"
else
  cat "$in"
fi
