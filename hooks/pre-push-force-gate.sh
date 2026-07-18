#!/usr/bin/env bash
# PreToolUse (Bash, git push): block bare force pushes (--force / -f) in ANY
# command form. Permission-rule globs only catch the literal prefix
# `git push --force …` — not `git push origin main --force`, `git -C … push -f`,
# or force pushes buried in compound commands. --force-with-lease stays allowed
# (the /rebase flow depends on it); force pushes to the default branch are
# already blocked by pre-push-branch-gate.sh regardless of flags.
# Bypass: set SKIP_PUSH_FORCE_GATE to any non-empty value.

set -u

[ -n "${SKIP_PUSH_FORCE_GATE:-}" ] && exit 0
command -v jq >/dev/null 2>&1 || exit 0

payload=$(cat 2>/dev/null) || exit 0
[ -n "$payload" ] || exit 0

cmd=$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null) || exit 0

# Join backslash-continued lines: a flag on a continuation line is still part
# of this push. Real newlines keep separating commands (cut below).
cmd=$(printf '%s\n' "$cmd" | awk '{ if (sub(/\\$/, "")) printf "%s ", $0; else print }')

# Quoted spans are data, not arguments: a commit message mentioning `git push`
# must not put this command through the push gates. Scan a copy with quoted
# content emptied — awk reads the whole input as one record so quotes spanning
# lines strip too (\047 = single quote).
scan=$(printf '%s' "$cmd" | awk 'BEGIN{RS="\001"} {gsub("\"[^\"]*\"","\"\""); gsub("\047[^\047]*\047","\047\047"); printf "%s", $0}')

# Match `git push …` and `git -C <path> push …`.
git_push_re="git[[:space:]]+(-C[[:space:]]+(\"[^\"]*\"|'[^']*'|[^[:space:]]+)[[:space:]]+)?push"
printf '%s\n' "$scan" | grep -Eq "${git_push_re}([[:space:]]|\$)" || exit 0

# Arguments of the push invocation: anchored on the `git … push` match itself
# — NOT on the word "push" anywhere, which latches onto data like the
# pre-push-*.sh filenames — cut at the next command separator (same pragmatic
# parse as pre-push-branch-gate.sh).
rest=$(printf '%s\n' "$scan" | sed -nE "s/.*${git_push_re}([[:space:]]|\$)//p" | head -1 | sed 's/[;&|].*//')

block() {
  "$(dirname "$0")/record-gate-block.sh" "pre-push-force-gate" "$payload" 2>/dev/null || true
  {
    echo "Blocked: $1"
    echo "If the remote must be overwritten, use --force-with-lease — and only"
    echo "after asking the user immediately before the push."
    echo "Bypass (human-only): '!'-prefix the command, or export SKIP_PUSH_FORCE_GATE=1 in your shell."
  } >&2
  exit 2
}

for tok in $rest; do
  case "$tok" in
    --force)
      block "bare force push ('--force') is never allowed." ;;
    # Long flags other than --force stay allowed: --force-with-lease,
    # --force-if-includes are the sanctioned path.
    --*) : ;;
    # git's option parser accepts bundled shorts (like `commit -am`), so
    # -fu / -uf force-push too — any single-dash token carrying an f blocks.
    -*f*)
      block "force push ('$tok' bundles -f) is never allowed." ;;
    # A +refspec has bare-force semantics with no lease.
    +*)
      block "'+refspec' push ('$tok') force-pushes without a lease." ;;
  esac
done

exit 0
