#!/usr/bin/env bash
# PreToolUse (Bash): warn when `gh` runs INSIDE the sandbox. gh keeps its
# login in a deny-read config file, so a sandboxed gh cannot start: depending
# on the subcommand it fails on "failed to read configuration", or prints
# nothing at all. Empty output is exactly what "no open PRs" or "no such
# branch" looks like, so the refusal reads as a finding.
#
# The same file breaks a sandboxed `git push` over https when git's credential
# helper for that remote is `gh auth git-credential` (what `gh auth setup-git`
# installs): the push fails on "could not read Username" before sending anything.
#
# Warn-only: the right move is to re-run with the sandbox disabled, which is
# gh or git reading its own credentials, not a bypass of anything.
#
# Bypass: set SKIP_BASH_GH_SANDBOX_GATE to any non-empty value.

set -u

[ -n "${SKIP_BASH_GH_SANDBOX_GATE:-}" ] && exit 0

payload=$(cat 2>/dev/null) || exit 0
[ -n "$payload" ] || exit 0

# Runs on EVERY Bash call: bail on a builtin match before spending a jq.
case "$payload" in
  *gh\ * | *push*) : ;;
  *) exit 0 ;;
esac

command -v jq >/dev/null 2>&1 || exit 0

unsandboxed=$(printf '%s' "$payload" | jq -r '.tool_input.dangerouslyDisableSandbox // false' 2>/dev/null) || exit 0
[ "$unsandboxed" = "true" ] && exit 0

cmd=$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null) || exit 0
[ -n "$cmd" ] || exit 0

# shellcheck source=hooks/hook-output-lib.sh
. "$(dirname "$0")/hook-output-lib.sh"

# gh as a command word: at the start, or after ; & | ( or $( — not inside a
# path or another word ("high", "~/.config/gh/", "git log --grep gh").
if printf '%s' "$cmd" | grep -Eq '(^|[;&|(]|\$\()[[:space:]]*gh[[:space:]]'; then
  hook_warn PreToolUse <<'EOF'
[gh-sandbox] This runs `gh` inside the sandbox. gh keeps its login in a
deny-read config file, so it fails or returns NOTHING here — and empty output
looks exactly like "no open PRs" or "no results". Re-run it with the sandbox
disabled before reading any result, and never treat an empty answer from a
sandboxed gh as a finding.
EOF
  exit 0
fi

push_uses_gh_helper() { # push_uses_gh_helper <command-string>
  # shellcheck source=hooks/git-cmd-lib.sh
  . "$(dirname "$0")/git-cmd-lib.sh" 2>/dev/null || return 1
  git_cmd_scan push "$1"
  local i=0 repo remote url helper arg skip
  local -a g
  while [ "$i" -lt "${GIT_CMD_N:-0}" ]; do
    g=(git)
    repo=$(git_cmd_repo "${GIT_CMD_CPATH[$i]}") && g+=(-C "$repo")
    # The remote is the first non-option argument; these options take a value.
    remote="" skip=""
    # shellcheck disable=SC2086  # GIT_CMD_ARGS is space-joined by contract
    for arg in ${GIT_CMD_ARGS[$i]}; do
      if [ -n "$skip" ]; then skip=""; continue; fi
      case "$arg" in
        -o | --push-option | --repo | --receive-pack | --exec) skip=1 ;;
        -*) ;;
        *) remote=$arg; break ;;
      esac
    done
    case "$remote" in
      https://*) url=$remote ;;
      *) url=$("${g[@]}" remote get-url --push "${remote:-origin}" 2>/dev/null) || url="" ;;
    esac
    case "$url" in
      https://*)
        helper=$("${g[@]}" config --get-urlmatch credential.helper "$url" 2>/dev/null) || helper=""
        case "$helper" in *"gh auth git-credential"*) return 0 ;; esac
        ;;
    esac
    i=$((i + 1))
  done
  return 1
}

push_uses_gh_helper "$cmd" || exit 0

hook_warn PreToolUse <<'EOF'
[gh-sandbox] This `git push` runs inside the sandbox over https, and git gets
its login for that remote from `gh auth git-credential`. That helper reads gh's
deny-read config, so the push fails ("could not read Username") before anything
is sent. Re-run the push with the sandbox disabled.
EOF
exit 0
