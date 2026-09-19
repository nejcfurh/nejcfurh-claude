#!/usr/bin/env bash
# PreToolUse (Bash, gh write commands): stop engagement-identifying text reaching a
# repo that is meant to stay generic. Scans the command line and any body file it
# references before a PR, issue or comment is created or edited.
#
# Why this exists: the check it replaces was a grep the model wrote inline and
# chained with `;`, so the create ran whatever the grep returned. A check that
# cannot fail the thing it guards is decoration. This one runs before the tool call
# and exits 2.
#
# Scope is opt-in per repo via a committed `.leak-guard` marker at the repo root.
# A client's own repo legitimately names its client in every PR body; enforcing
# there would block normal work and teach the bypass. The marker carries no names.
#
# Patterns come from two places:
#   - built in: the ticket-key shape (ABC-123), which identifies an engagement
#     regardless of whose it is and needs no configuration
#   - optional: one regex per line in $CLAUDE_LEAK_PATTERNS, else
#     $HOME/.claude/leak-patterns — private, never in any repo, `#` comments ignored
#
# Matched text is never echoed: printing the client name into the transcript is the
# disclosure this gate exists to prevent. Only the pattern class and source are named.
# Bypass: set SKIP_LEAK_GATE to any non-empty value.

set -u

[ -n "${SKIP_LEAK_GATE:-}" ] && exit 0
command -v jq >/dev/null 2>&1 || exit 0

payload=$(cat 2>/dev/null) || exit 0
[ -n "$payload" ] || exit 0

cmd=$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null) || exit 0
[ -n "$cmd" ] || exit 0

# Only outbound writes carry a body to a shared surface. A read never does.
case "$cmd" in
  *"gh pr create"* | *"gh pr edit"* | *"gh pr comment"* | *"gh issue create"* | *"gh issue edit"* | \
    *"gh issue comment"* | *"gh release create"* | *"gh api"*) ;;
  *) exit 0 ;;
esac

# A leading `cd <path> &&` moves the directory the gh command runs in, and the
# payload's cwd is the session's, not that one. Without this the gate resolves the
# wrong repo and goes inert exactly when the command is reaching into the guarded
# one — a false ALLOW, and the failure mode that made the first live test pass
# a body it should have blocked.
# Parameter expansion rather than sed: BSD sed has no \| alternation in a basic
# regex, so the portable-looking version silently matched nothing here.
cd_target=""
case "$cmd" in
  "cd "*)
    cd_target=${cmd#cd }
    cd_target=${cd_target%%&&*}
    cd_target=${cd_target%%;*}
    cd_target=${cd_target% }
    cd_target=${cd_target#\"}
    cd_target=${cd_target%\"}
    cd_target=${cd_target#\'}
    cd_target=${cd_target%\'}
    ;;
esac
# An unexpanded variable in the path cannot be resolved here.
case "$cd_target" in *'$'*) cd_target="" ;; esac

repo_root=""
for candidate in "$cd_target" "$PWD"; do
  [ -n "$candidate" ] || continue
  [ -d "$candidate" ] || continue
  if root=$(git -C "$candidate" rev-parse --show-toplevel 2>/dev/null); then
    repo_root="$root"
    break
  fi
done
[ -n "$repo_root" ] || exit 0
[ -f "$repo_root/.leak-guard" ] || exit 0

patterns_file="${CLAUDE_LEAK_PATTERNS:-$HOME/.claude/leak-patterns}"

# Body files: `--body-file X`, `-F body=@X`, `--field body=@X`. Read them too, since
# the identifying text usually lives there rather than on the command line.
targets=""
prev=""
for word in $cmd; do
  case "$word" in
    --body-file=*) targets="$targets ${word#--body-file=}" ;;
    body=@*) targets="$targets ${word#body=@}" ;;
  esac
  case "$prev" in
    --body-file | -F | --field)
      case "$word" in
        body=@*) : ;;
        -*) : ;;
        *) targets="$targets $word" ;;
      esac
      ;;
  esac
  prev="$word"
done

scan_text=$(printf '%s\n' "$cmd")
for target in $targets; do
  [ -n "$target" ] || continue
  candidate="$target"
  [ -f "$candidate" ] || candidate="$repo_root/$target"
  [ -f "$candidate" ] || continue
  scan_text="$scan_text
$(cat "$candidate" 2>/dev/null)"
done

hits=""
add_hit() { # add_hit <class>
  case "$hits" in
    *"$1"*) ;;
    *) hits="$hits $1" ;;
  esac
}

# Built in: a ticket key identifies an engagement whoever owns it. The gate's own
# marker filename and this hook's name are excluded so it can describe itself.
if printf '%s' "$scan_text" | grep -qE '\b[A-Z]{2,10}-[0-9]+\b'; then
  add_hit "ticket-key"
fi

if [ -f "$patterns_file" ]; then
  while IFS= read -r pattern; do
    case "$pattern" in '' | '#'*) continue ;; esac
    if printf '%s' "$scan_text" | grep -qiwE "$pattern" 2>/dev/null; then
      add_hit "private-pattern"
    fi
  done <"$patterns_file"
fi

[ -n "$hits" ] || exit 0

"$(dirname "$0")/record-gate-block.sh" "pre-gh-outbound-leak-gate" "$payload" 2>/dev/null || true
{
  echo "Blocked: this repo carries .leak-guard, and the text about to be published matches:${hits}"
  echo ""
  echo "  ticket-key      an identifier of the form ABC-123"
  echo "  private-pattern an entry in ${patterns_file/#$HOME/~}"
  echo ""
  echo "The matched text is deliberately not shown — echoing it here would be the same disclosure."
  echo "Generalize it: 'a ticket', 'a client project', 'an internal convention'. A lesson that needs"
  echo "the original named is not yet a rule."
  echo ""
  echo "Bypass (human-only): '!'-prefix the command, or export SKIP_LEAK_GATE=1 in your shell."
} >&2
exit 2
