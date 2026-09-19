#!/usr/bin/env bash
# Shared pattern source for the leak gates, so the outbound path and the commit
# path cannot drift apart on what counts as identifying.
#
# Two classes:
#   ticket-key       built in: an identifier shaped as letters-hyphen-digits, which names an
#                    engagement whoever owns it, so it needs no configuration
#   private-pattern  one regex per line in $CLAUDE_LEAK_PATTERNS, else
#                    $HOME/.claude/leak-patterns — the names being protected cannot
#                    themselves live in a shared repo, so the list never does
#
# Matched text is never returned, only the class. Echoing it into a transcript or a
# block message is the same disclosure the gates exist to prevent.

leak_patterns_file() {
  printf '%s' "${CLAUDE_LEAK_PATTERNS:-$HOME/.claude/leak-patterns}"
}

# leak_scan <text> — prints the matched classes, space separated, or nothing.
leak_scan() {
  local text="$1" hits="" patterns_file
  patterns_file=$(leak_patterns_file)

  if printf '%s' "$text" | grep -qE '\b[A-Z]{2,10}-[0-9]+\b'; then
    hits=" ticket-key"
  fi

  if [ -f "$patterns_file" ]; then
    while IFS= read -r pattern; do
      case "$pattern" in '' | '#'*) continue ;; esac
      if printf '%s' "$text" | grep -qiwE "$pattern" 2>/dev/null; then
        case "$hits" in
          *private-pattern*) ;;
          *) hits="$hits private-pattern" ;;
        esac
      fi
    done <"$patterns_file"
  fi

  printf '%s' "$hits"
}

# leak_guard_repo <repo-root> — true when the repo opts in via a committed marker.
leak_guard_repo() {
  [ -n "$1" ] && [ -f "$1/.leak-guard" ]
}

# leak_allow_globs <repo-root> — pathspecs exempt from the staged-content scan,
# read from `allow: <glob>` lines in .leak-guard.
#
# A matcher's own tests have to contain the thing it forbids, so without this the
# gate blocks the commit that adds it and the only way forward is the bypass — which
# is how a guard teaches people to switch it off. The exemption covers file content
# only: a commit MESSAGE is never exempt, since that is where identifiers leak most.
leak_allow_globs() {
  local root="$1" line
  [ -f "$root/.leak-guard" ] || return 0
  while IFS= read -r line; do
    case "$line" in
      'allow:'*)
        line=${line#allow:}
        line=${line# }
        [ -n "$line" ] && printf '%s\n' "$line"
        ;;
    esac
  done <"$root/.leak-guard"
}

# leak_block_explainer — the shared tail of a block message.
leak_block_explainer() {
  local patterns_file
  patterns_file=$(leak_patterns_file)
  echo "  ticket-key      a ticket-shaped identifier: letters, hyphen, digits"
  echo "  private-pattern an entry in ${patterns_file/#$HOME/~}"
  echo ""
  echo "The matched text is deliberately not shown — echoing it here would be the same disclosure."
  echo "Generalize it: 'a ticket', 'a client project', 'an internal convention'. A lesson that needs"
  echo "the original named is not yet a rule."
}
