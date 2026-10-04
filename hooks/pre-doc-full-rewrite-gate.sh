#!/usr/bin/env bash
# PreToolUse (MCP page update): ask before a full-page rewrite of a shared document.
#
# A document tool's "replace whole page" command rewrites the page from the
# version the model last fetched. Anything a person changed in between — a
# reworded summary, a footnote, a comment anchor — is discarded, and nothing
# reports it: the call succeeds, the page looks complete, and the loss is found
# by whoever made the edit. The habit forms innocently: one targeted edit fails
# to match, the full rewrite works, and from then on every edit is a rewrite.
#
# Targeted commands (search-and-replace, insert) touch only what they name, so
# they are the default. A rewrite is sometimes unavoidable — an image has to
# change and cannot be addressed by text — so this gate asks rather than denies,
# and says what to check first.
#
# Fires only when the tool input's `command` is `replace_content`. Every other
# command, an empty payload, or a payload without a command passes silently.
#
# Bypass: set SKIP_DOC_FULL_REWRITE_GATE to any non-empty value.

set -u

[ -n "${SKIP_DOC_FULL_REWRITE_GATE:-}" ] && exit 0

payload=$(cat 2>/dev/null) || exit 0
[ -n "$payload" ] || exit 0

command -v jq >/dev/null 2>&1 || exit 0

cmd=$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null) || exit 0
[ "$cmd" = "replace_content" ] || exit 0

# read -d '' instead of $(cat <<EOF): bash 3.2 (macOS /bin/bash) scans a heredoc
# inside $(...) for quote pairs, so an apostrophe in the text is a syntax error.
reason=""
read -r -d '' reason <<'MSG' || true
replace_content rewrites the whole page from the version you last fetched. Every edit a person made since — wording, footnotes, comment anchors — is discarded, and the call reports success.

Prefer a targeted command: update_content with the smallest unique old_str (headings and sentences match; an image cannot be targeted, its URL is a per-fetch signed link), or insert_content to append. If a full rewrite is unavoidable: fetch immediately before, confirm the page's last-edited time matches your last fetch, copy any comment-anchor spans verbatim, and reuse the existing file-upload ids for images that did not change.

False positive? Set SKIP_DOC_FULL_REWRITE_GATE=1 for the call.
MSG

jq -cn --arg r "$reason" \
  '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"ask",permissionDecisionReason:$r}}'
exit 0
