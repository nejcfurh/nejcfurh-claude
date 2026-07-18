#!/usr/bin/env bash
# PreToolUse (Bash: git push / git commit / gh pr): inject ground-truth PR state
# as additional context so Claude does not act on stale conversation memory.
# This hook NEVER blocks - every code path exits 0.

set -u

# Print the context line in the hook JSON envelope and exit.
emit() {
  jq -n --arg ctx "$1" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",additionalContext:$ctx}}' 2>/dev/null
  exit 0
}

command -v jq >/dev/null 2>&1 || exit 0

payload=$(cat 2>/dev/null) || exit 0
[ -n "$payload" ] || exit 0

# Only refresh for commands that act on PR state — anything else would pay a
# GitHub API round-trip on every Bash call. Covers `git -C <path>` forms too.
cmd=$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null) || exit 0
case "$cmd" in
  *"git push"*|*"git commit"*|*"gh pr "*) : ;;
  *)
    printf '%s\n' "$cmd" | grep -Eq "git[[:space:]]+-C[[:space:]]+(\"[^\"]*\"|'[^']*'|[^[:space:]]+)[[:space:]]+(push|commit)([[:space:]]|\$)" || exit 0
    ;;
esac

# Resolve the repo: cwd first, then the project dir.
repo=""
if git -C "$PWD" rev-parse --show-toplevel >/dev/null 2>&1; then
  repo="$PWD"
elif [ -n "${CLAUDE_PROJECT_DIR:-}" ] && git -C "$CLAUDE_PROJECT_DIR" rev-parse --show-toplevel >/dev/null 2>&1; then
  repo="$CLAUDE_PROJECT_DIR"
fi
[ -n "$repo" ] || emit "[pr-state] unavailable=not-a-repo"

command -v gh >/dev/null 2>&1 || emit "[pr-state] unavailable=no-gh"

branch=$(git -C "$repo" branch --show-current 2>/dev/null)
[ -n "$branch" ] || branch="(detached)"

# Query the PR for the current branch, bounded so the hook never hangs.
if command -v perl >/dev/null 2>&1; then
  pr_json=$(cd "$repo" && perl -e 'alarm shift @ARGV; exec @ARGV' 10 \
    gh pr view --json state,mergedAt,url,statusCheckRollup 2>/dev/null)
else
  pr_json=$(cd "$repo" && gh pr view --json state,mergedAt,url,statusCheckRollup 2>/dev/null)
fi
if [ $? -ne 0 ] || [ -z "$pr_json" ]; then
  emit "[pr-state] branch=$branch no-open-pr"
fi

# Summarize the check rollup as one word: failing > pending > passing, or none.
parsed=$(printf '%s' "$pr_json" | jq -r '
  def bucket:
    (.conclusion // .state // "") as $v
    | if $v == "SUCCESS" or $v == "NEUTRAL" or $v == "SKIPPED" then "pass"
      elif $v == "FAILURE" or $v == "ERROR" or $v == "CANCELLED" or $v == "TIMED_OUT" then "fail"
      else "pending" end;
  (.statusCheckRollup // []) as $c
  | (if ($c | length) == 0 then "none"
     elif ([$c[] | bucket] | map(select(. == "fail")) | length) > 0 then "failing"
     elif ([$c[] | bucket] | map(select(. == "pending")) | length) > 0 then "pending"
     else "passing" end) as $checks
  | [(.state // "UNKNOWN"), $checks, (.url // "")] | @tsv
' 2>/dev/null)
[ -n "$parsed" ] || emit "[pr-state] branch=$branch no-open-pr"

state=$(printf '%s\n' "$parsed" | cut -f1)
checks=$(printf '%s\n' "$parsed" | cut -f2)
url=$(printf '%s\n' "$parsed" | cut -f3)

line="[pr-state] branch=$branch state=$state checks=$checks url=$url"
case "$state" in
  MERGED|CLOSED)
    line="$line WARNING: this PR is $state - confirm intent with the user before pushing to or editing it."
    ;;
esac

emit "$line"
