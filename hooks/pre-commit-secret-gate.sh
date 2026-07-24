#!/usr/bin/env bash
# PreToolUse (Bash, git commit): scan the changes a commit would publish for
# secrets before they enter history. Runs gitleaks over the staged index when
# installed, plus a dependency-free high-confidence pattern scan over staged
# and unstaged tracked changes AND untracked files — the command may run
# `git add` right before committing, so the index alone is not enough.
# Matched content is never echoed; only the pattern class and file are named.
# Bypass: set SKIP_SECRET_GATE to any non-empty value.

set -u

[ -n "${SKIP_SECRET_GATE:-}" ] && exit 0
command -v jq >/dev/null 2>&1 || exit 0

payload=$(cat 2>/dev/null) || exit 0
[ -n "$payload" ] || exit 0

cmd=$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null) || exit 0

# shellcheck source=hooks/git-cmd-lib.sh
. "$(dirname "$0")/git-cmd-lib.sh"

git_cmd_scan commit "$cmd"
[ "$GIT_CMD_N" -gt 0 ] || exit 0

# The first invocation's repo: `git -C <path>` or a leading `cd <path> &&` wins
# over the cwd. A command committing to two different repos at once scans only
# the first — the same single-repo scope this gate has always had.
repo=$(git_cmd_repo "${GIT_CMD_CPATH[0]}" "$cmd") || exit 0

block() { # block <details…>
  "$(dirname "$0")/record-gate-block.sh" "pre-commit-secret-gate" "$payload" 2>/dev/null || true
  {
    echo "Blocked: the changes this commit would publish look like they contain secrets."
    echo ""
    printf '%s\n' "$@"
    echo ""
    echo "Remove the secret (and rotate it if it was ever real), then commit again."
    echo "Bypass (human-only): '!'-prefix the command, or export SKIP_SECRET_GATE=1 in your shell."
  } >&2
  exit 2
}

# 1) gitleaks over the staged index, when installed.
if [ -z "${SECRET_GATE_SKIP_GITLEAKS:-}" ] && command -v gitleaks >/dev/null 2>&1; then
  if ! git -C "$repo" diff --cached --quiet 2>/dev/null; then
    out=$(cd "$repo" && gitleaks protect --staged --no-banner --no-color --redact 2>&1)
    if [ $? -ne 0 ]; then
      block "gitleaks findings (staged index):" "$(printf '%s\n' "$out" | tail -n 20)"
    fi
  fi
fi

# 2) Built-in high-confidence patterns. Each entry is "<label>:<ERE>"; labels
# are printed, matched content never is.
checks="private key material:-----BEGIN[A-Z ]* PRIVATE KEY( BLOCK)?-----
AWS access key id:AKIA[0-9A-Z]{16}
GitHub token:gh[pousr]_[A-Za-z0-9]{36}
GitHub fine-grained PAT:github_pat_[A-Za-z0-9_]{22}
Anthropic API key:sk-ant-[A-Za-z0-9_-]{20}
Stripe live key:sk_live_[0-9A-Za-z]{20}
Slack token:xox[baprs]-[0-9A-Za-z-]{10}
Google API key:AIza[0-9A-Za-z_-]{35}"

if git -C "$repo" rev-parse --verify -q HEAD >/dev/null 2>&1; then
  added=$(git -C "$repo" diff HEAD -U0 --no-color 2>/dev/null | grep '^+' | grep -v '^+++')
else
  added=$(git -C "$repo" diff --cached -U0 --no-color 2>/dev/null | grep '^+' | grep -v '^+++')
fi

findings=""
while IFS= read -r check; do
  [ -n "$check" ] || continue
  label="${check%%:*}"
  re="${check#*:}"
  if [ -n "$added" ] && printf '%s\n' "$added" | grep -EIq -- "$re"; then
    findings="$findings
  - $label (in staged/unstaged tracked changes)"
  fi
done <<EOF_CHECKS
$checks
EOF_CHECKS

# Untracked files: anything `git add -A` would pick up. Bounded scan.
untracked=$(git -C "$repo" ls-files --others --exclude-standard 2>/dev/null | head -200)
while IFS= read -r f; do
  [ -n "$f" ] || continue
  [ -f "$repo/$f" ] || continue
  while IFS= read -r check; do
    [ -n "$check" ] || continue
    label="${check%%:*}"
    re="${check#*:}"
    if head -c 262144 "$repo/$f" 2>/dev/null | grep -EIq -- "$re"; then
      findings="$findings
  - $label (untracked file: $f)"
      break
    fi
  done <<EOF_CHECKS2
$checks
EOF_CHECKS2
done <<EOF_FILES
$untracked
EOF_FILES

if [ -n "$findings" ]; then
  block "Pattern matches:$findings"
fi

exit 0
