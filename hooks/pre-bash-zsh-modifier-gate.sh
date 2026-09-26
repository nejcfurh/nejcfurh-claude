#!/usr/bin/env bash
# PreToolUse (Bash): warn when a command run by zsh expands an unbraced
# parameter directly followed by ":" and a letter, such as "$REF:lib/x.ts".
#
# zsh reads ":<letter>" after an unbraced parameter as a history modifier and
# applies it: ":l" lowercases, ":h" takes the head, ":a" makes the path
# absolute, ":c" resolves a command. So `git show "$REF:lib/x.ts"` silently
# becomes `git show "<lowercased ref>ib/x.ts"`, and the command fails with an
# error about a revision or a path that nobody typed. Double quotes do not
# protect it. The same line works in bash, which is why it keeps recurring:
# the command looks right, and a note in memory did not stop it.
#
# Non-blocking by design. The fix is to brace the name, "${REF}:lib/x.ts", or
# to spell the value out. Single-quoted text is not expanded and is ignored.
# A heredoc fed to bash can still trip the warning; ignore it there.
#
# Only speaks when the session shell is zsh; bash does not apply modifiers.
#
# Bypass: set SKIP_BASH_ZSH_MODIFIER_GATE to any non-empty value.

set -u

[ -n "${SKIP_BASH_ZSH_MODIFIER_GATE:-}" ] && exit 0

case "${SHELL:-}" in
  *zsh) : ;;
  *) exit 0 ;;
esac

payload=$(cat 2>/dev/null) || exit 0
[ -n "$payload" ] || exit 0

# Runs on EVERY Bash call: bail on a builtin match before spending a jq.
case "$payload" in
  *'$'*:*) : ;;
  *) exit 0 ;;
esac

command -v jq >/dev/null 2>&1 || exit 0

cmd=$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null) || exit 0
[ -n "$cmd" ] || exit 0

# Drop single-quoted segments: zsh does not expand inside them.
unquoted=$(printf '%s' "$cmd" | sed "s/'[^']*'//g")

match=$(printf '%s' "$unquoted" | grep -oE '\$([A-Za-z_][A-Za-z0-9_]*|[0-9]):[aAcehlPqQrstux]' | head -n1)
[ -n "$match" ] || exit 0

name=${match%%:*}
cat <<EOF
[zsh-modifier] This command expands ${match}… — zsh reads ":${match##*:}" after an
unbraced parameter as a history modifier and rewrites the value (":l" lowercases,
":h" takes the head, ":a" makes it absolute), even inside double quotes. Brace the
name — "\${${name#\$}}:…" — or spell the value out. If this text runs under bash or
sits in a quoted heredoc, ignore this.
EOF
exit 0
