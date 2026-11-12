#!/usr/bin/env bash
# PreToolUse (Bash): two zsh traps that bash does not have. One script, so the
# check costs one process on every Bash call instead of two.
#
# 1. BLOCK an unquoted word that zsh is certain to reject before anything runs
#    past it:
#      - an option with a glob after "=", such as --include=*.ts. zsh globs the
#        whole word, no file is named "--include=…", and the command aborts with
#        "no matches found". This was 396 failed calls in 30 days of transcripts.
#      - a word starting with "==", such as `echo ====` or `[ a == b ]`. zsh
#        reads "=word" as "the path of command word", finds none, and aborts with
#        "= not found". 84 failed calls in the same 30 days.
#    A block costs nothing that would have run: zsh fails on these anyway, but
#    only after the steps before them in the same line have run. The fix is to
#    quote the word. A bare "=" and "=cmd" are valid zsh and are left alone, as
#    is "==" inside [[ ]] or (( )), where zsh does not expand it.
#
# 2. WARN when an unbraced parameter is directly followed by ":" and a letter,
#    such as "$REF:lib/x.ts". zsh reads ":<letter>" as a history modifier and
#    applies it: ":l" lowercases, ":h" takes the head, ":a" makes the path
#    absolute. So `git show "$REF:lib/x.ts"` silently becomes a different
#    revision. Double quotes do not protect it. The fix is "${REF}:lib/x.ts".
#    A heredoc fed to bash can still trip the warning; ignore it there.
#
# Quoted text, escaped characters and here-document bodies are data, not words,
# and never trip either check. Only speaks when the session shell is zsh.
# Known gaps: a "$( … )" inside double quotes is read as quoted text, and a glob
# that does not follow the "=" directly (--include=src/*.ts) passes the cheap
# pre-check. Neither is blocked. Against 30 days of transcripts the block caught
# 314 of 316 real failures and refused no command that would have run.
#
# Wiring: the block needs the hook's exit status, so settings.json runs it with
# `exec "$HOOK"`, not `"$HOOK" || true`.
#
# Bypass: SKIP_BASH_ZSH_GLOB_GATE silences the block, SKIP_BASH_ZSH_MODIFIER_GATE
# silences everything.

set -u

[ -n "${SKIP_BASH_ZSH_MODIFIER_GATE:-}" ] && exit 0

case "${SHELL:-}" in
  *zsh) : ;;
  *) exit 0 ;;
esac

payload=$(cat 2>/dev/null) || exit 0
[ -n "$payload" ] || exit 0

# Runs on EVERY Bash call: bail on a builtin match before spending a jq. The
# block needs "=" directly before a glob character or another "=", the warning
# a "$…:". A bare "=" is in over half of all commands, so it is not enough.
case "$payload" in
  *'=*'* | *'=?'* | *'=['* | *'=='* | *'$'*:*) : ;;
  *) exit 0 ;;
esac

command -v jq >/dev/null 2>&1 || exit 0

cmd=$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null) || exit 0
[ -n "$cmd" ] || exit 0

# --- 1. block ---------------------------------------------------------------

# Prints "glob<TAB>word" or "eq<TAB>word" for the first unquoted word zsh will
# reject, or nothing. A character state machine, because only it knows whether
# a "*" or "==" is code or data. Each word is built twice: `tok` holds the text,
# `u` the same text with every quoted or escaped character replaced by "_", so
# a test on `u` sees only what zsh would expand.
zsh_rejects() {
  awk '
    function flush(   eqi) {
      if (!have) return
      if (tok == "[[") incond = 1
      else if (tok == "]]") incond = 0
      else if (!found && !incond && !noeq && u ~ /^==/) { found = "eq\t" tok }
      else if (!found && !noglob && tok ~ /^-[^=]*=/) {
        eqi = index(tok, "=")
        if (substr(u, eqi + 1) ~ /[*?[]/) found = "glob\t" tok
      }
      tok = ""; u = ""; have = 0
    }
    function add(c, quoted) { tok = tok c; u = u (quoted ? "_" : c); have = 1 }
    BEGIN { RS = "\001" }
    {
      s = $0; n = length(s); st = 0; nhd = 0; hdi = 0
      noglob = (s ~ /noglob|nomatch|null_?glob/)
      noeq = (s ~ /no_?equals/)
      for (i = 1; i <= n; i++) {
        c = substr(s, i, 1)
        if (st == 1) { if (c == "\047") st = 0; else add(c, 1); continue }
        if (st == 3) {
          if (c == "\\") { i++; add(substr(s, i, 1), 1); continue }
          if (c == "\047") st = 0; else add(c, 1); continue
        }
        if (st == 2) {
          if (c == "\\") { i++; add(substr(s, i, 1), 1); continue }
          if (c == "\"") st = 0; else add(c, 1); continue
        }
        # st == 0: unquoted
        if (c == "\\") { i++; if (substr(s, i, 1) != "\n") add(substr(s, i, 1), 1); continue }
        if (c == "\047") { st = 1; have = 1; continue }
        if (c == "\"") { st = 2; have = 1; continue }
        if (c == "$" && substr(s, i + 1, 1) == "\047") { i++; st = 3; have = 1; continue }
        # ${…} is a parameter expansion: its "*" or "?" is an operator, not a glob.
        if (c == "$" && substr(s, i + 1, 1) == "{") {
          d = 0
          for (; i <= n; i++) {
            c = substr(s, i, 1); add(c, 1)
            if (c == "{") d++
            else if (c == "}" && --d == 0) break
          }
          continue
        }
        # (( … )) is arithmetic: "==" there is a comparison.
        if (c == "(" && substr(s, i + 1, 1) == "(") {
          flush(); j = index(substr(s, i + 2), "))")
          i = (j ? i + j + 2 : n); continue
        }
        # Comment to end of line, but only where a word would start.
        if (c == "#" && !have) {
          while (i < n && substr(s, i + 1, 1) != "\n") i++
          continue
        }
        # Here-document operator (not the <<< here-string): queue its delimiter.
        if (c == "<" && substr(s, i + 1, 1) == "<" && substr(s, i + 2, 1) != "<") {
          flush(); i += 2
          strip = 0
          if (substr(s, i, 1) == "-") { strip = 1; i++ }
          while (substr(s, i, 1) == " " || substr(s, i, 1) == "\t") i++
          d = ""
          for (; i <= n; i++) {
            c = substr(s, i, 1)
            if (c ~ /[ \t\n;&|<>()]/) break
            if (c != "\047" && c != "\"" && c != "\\") d = d c
          }
          i--
          if (d != "") { nhd++; hdterm[nhd] = d; hdstrip[nhd] = strip }
          continue
        }
        if (c == "\n") {
          flush()
          # Skip each queued here-document body, in order.
          while (hdi < nhd) {
            hdi++
            for (;;) {
              if (i >= n) break
              e = index(substr(s, i + 1), "\n")
              line = e ? substr(s, i + 1, e - 1) : substr(s, i + 1)
              i = e ? i + e : n
              if (hdstrip[hdi]) sub(/^\t+/, "", line)
              if (line == hdterm[hdi]) break
            }
          }
          continue
        }
        if (c ~ /[ \t;&|(){}`<>]/) { flush(); continue }
        add(c, 0)
      }
      flush()
      if (found) print found
    }
  '
}

if [ -z "${SKIP_BASH_ZSH_GLOB_GATE:-}" ]; then
  case "$cmd" in
    *'=*'* | *'=?'* | *'=['* | *'=='*)
      hit=$(printf '%s' "$cmd" | zsh_rejects)
      if [ -n "$hit" ]; then
        kind=${hit%%	*}
        word=${hit#*	}
        HELPER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/record-gate-block.sh"
        [ -x "$HELPER" ] && "$HELPER" zsh-glob "$payload" >/dev/null 2>&1
        if [ "$kind" = "glob" ]; then
          printf '%s\n' \
            "BLOCKED: zsh will abort this command at the unquoted word  ${word}" \
            "zsh globs the whole word, no file matches, and it stops with \"no matches" \
            "found\" after running whatever came before it. Quote the pattern:" \
            "  ${word%%=*}='${word#*=}'" >&2
        else
          printf '%s\n' \
            "BLOCKED: zsh will abort this command at the unquoted word  ${word}" \
            "zsh reads a word starting with \"=\" as the path of a command, finds none," \
            "and stops with \"= not found\". Quote it ('${word}'), or compare inside" \
            "[[ … ]] instead of [ … ]." >&2
        fi
        echo "Bypass (human-only): SKIP_BASH_ZSH_GLOB_GATE=1." >&2
        exit 2
      fi
      ;;
  esac
fi

# --- 2. warn ----------------------------------------------------------------

case "$cmd" in
  *'$'*:*) : ;;
  *) exit 0 ;;
esac

# Drop single-quoted segments: zsh does not expand inside them.
unquoted=$(printf '%s' "$cmd" | sed "s/'[^']*'//g")

match=$(printf '%s' "$unquoted" | grep -oE '\$([A-Za-z_][A-Za-z0-9_]*|[0-9]):[aAcehlPqQrstux]' | head -n1)
[ -n "$match" ] || exit 0

name=${match%%:*}
# shellcheck source=hooks/hook-output-lib.sh
. "$(dirname "$0")/hook-output-lib.sh"
# printf, not a heredoc: bash writes a heredoc to a temp file, and where that
# file cannot be created the warning vanishes without an error.
printf '%s\n' \
  "[zsh-modifier] This command expands ${match}… — zsh reads \":${match##*:}\" after an" \
  "unbraced parameter as a history modifier and rewrites the value (\":l\" lowercases," \
  "\":h\" takes the head, \":a\" makes it absolute), even inside double quotes. Brace the" \
  "name — \"\${${name#\$}}:…\" — or spell the value out. If this text runs under bash or" \
  "sits in a quoted heredoc, ignore this." | hook_warn PreToolUse
exit 0
