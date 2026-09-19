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
#   - built in: the ticket-key shape — letters, a hyphen, digits — which identifies an engagement
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

# shellcheck source=hooks/leak-patterns-lib.sh
. "$(dirname "$0")/leak-patterns-lib.sh"

leak_guard_repo "$repo_root" || exit 0

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

# Paths in the command are not prose. A body file living under a project directory,
# or a command run inside one, names that project in an argument — scanning those
# verbatim blocks every publish from the guarded repo. Tokens with a slash are paths.
scan_text=$(printf '%s' "$cmd" | tr ' ' '\n' | grep -v '/' | tr '\n' ' ')
for target in $targets; do
  [ -n "$target" ] || continue
  candidate="$target"
  [ -f "$candidate" ] || candidate="$repo_root/$target"
  [ -f "$candidate" ] || continue
  scan_text="$scan_text
$(cat "$candidate" 2>/dev/null)"
done

hits=$(leak_scan "$scan_text")
[ -n "$hits" ] || exit 0

"$(dirname "$0")/record-gate-block.sh" "pre-gh-outbound-leak-gate" "$payload" 2>/dev/null || true
{
  echo "Blocked: this repo carries .leak-guard, and the text about to be published matches:$hits"
  echo ""
  leak_block_explainer
  echo ""
  echo "Bypass (human-only): '!'-prefix the command, or export SKIP_LEAK_GATE=1 in your shell."
} >&2
exit 2
