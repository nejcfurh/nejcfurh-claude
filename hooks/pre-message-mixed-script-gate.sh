#!/usr/bin/env bash
# PreToolUse (a tool that sends or drafts a message: chat, email, ticket comment):
# refuse the call when one word mixes Latin letters with Cyrillic or Greek ones.
#
# A model writing in a language with diacritics can emit a look-alike letter from
# another script inside a Latin word. It renders identically, so neither the
# author nor a reviewer sees it, and the recipient's spell checker, search and
# copy-paste all treat the word as garbage. Drafts saved through an API often
# cannot be edited from the session afterwards, so the check has to come first.
#
# Words written wholly in Cyrillic or Greek pass; only a mix inside one word is
# refused. The micro and ohm signs pass, so units like 5μm and 10kΩ do not trip it.
#
# Bypass: set SKIP_MIXED_SCRIPT_GATE to any non-empty value.

set -u

[ -n "${SKIP_MIXED_SCRIPT_GATE:-}" ] && exit 0

payload=$(cat 2>/dev/null) || exit 0
[ -n "$payload" ] || exit 0

command -v jq >/dev/null 2>&1 || exit 0
command -v perl >/dev/null 2>&1 || exit 0

text=$(printf '%s' "$payload" | jq -r '[.tool_input | .. | strings] | join("\n")' 2>/dev/null) || exit 0
[ -n "$text" ] || exit 0

words=$(printf '%s' "$text" | perl -CSD -ne '
  while (/(\w+)/g) {
    my $w = $1;
    print "$w\n" if $w =~ /\p{Latin}/ && $w =~ /(?![\x{03BC}\x{03A9}\x{2126}])[\p{Cyrillic}\p{Greek}]/;
  }
' 2>/dev/null | sort -u | head -5)
[ -n "$words" ] || exit 0

"$(dirname "$0")/record-gate-block.sh" "pre-message-mixed-script-gate" "$payload" 2>/dev/null || true

listed=$(printf '%s' "$words" | sed 's/^/  - /')
reason=""
read -r -d '' reason <<MSG || true
This message has words that mix Latin letters with Cyrillic or Greek look-alikes. They render the same but break spelling, search and copy-paste for the recipient:
$listed

Retype each word in one script, then send again.

False positive? Set SKIP_MIXED_SCRIPT_GATE=1 for the call.
MSG

jq -cn --arg r "$reason" \
  '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
exit 0
