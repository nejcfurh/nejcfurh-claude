#!/usr/bin/env bash
# Shared git command-line parsing for the git gates. SOURCED, never executed —
# running it does nothing. The executable bit exists only because
# scripts/lint-config.sh requires it of every hooks/*.sh.
#
# Why this exists: every gate used to detect its own subcommand, and all of them
# fell back to the literal substring "git commit" / "git push" when the
# `git -C <path>` regex missed. A literal single-space substring matches no
# git-level option and not even a double space, so `git --no-pager commit`,
# `git  push origin main`, and a second `git push` later on the same line walked
# past all eight gates at once. One tokenizer here replaces five hand-rolled
# regexes so they cannot drift apart again.
#
# Token contract: quotes are stripped and a newline inside a quoted token becomes
# a space, so a multi-line commit message is NOT reproduced faithfully. Gates
# needing the message text re-extract it from the raw command themselves.
#
# Known residuals: a wrapper that takes a value argument (`nice -n 10 git push`)
# and command substitution (`$(git push)`) are not resolved — the same residuals
# pre-git-meta-gate.sh documents.

# Emit one line per token, prefixed "T", plus a bare "S" line at each command
# separator found OUTSIDE quotes. A character state machine is the only way to
# know whether a `;` or the word `git` is code or data — the substring matches
# this replaces could not tell, which is why a commit message mentioning
# "git push" used to put a command through the push gates.
_git_cmd_tokenize() {
  awk '
    BEGIN { RS = "\001" }
    {
      n = length($0); state = 0; tok = ""; have = 0
      for (i = 1; i <= n; i++) {
        c = substr($0, i, 1)
        if (state == 0) {
          if (c == "\\") { i++; nc = substr($0, i, 1); if (nc != "\n") { tok = tok nc; have = 1 }; continue }
          if (c == "\047") { state = 1; have = 1; continue }
          if (c == "\"") { state = 2; have = 1; continue }
          if (c == " " || c == "\t") { if (have) { print "T" tok; tok = ""; have = 0 }; continue }
          if (c == "\n" || c == ";" || c == "&" || c == "|") {
            if (have) { print "T" tok; tok = ""; have = 0 }
            print "S"; continue
          }
          tok = tok c; have = 1; continue
        }
        if (state == 1) {
          if (c == "\047") { state = 0; continue }
          tok = tok (c == "\n" ? " " : c); continue
        }
        if (c == "\\") { i++; nc = substr($0, i, 1); if (nc != "\n") tok = tok nc; continue }
        if (c == "\"") { state = 0; continue }
        tok = tok (c == "\n" ? " " : c)
      }
      if (have) print "T" tok
    }
  '
}

# Inspect one segment's tokens and record it when it is `git … <want> …`.
_git_cmd_segment() { # _git_cmd_segment <want> <token…>
  local want="$1"
  shift

  # Leading env assignments and command wrappers precede the command word.
  while [ "$#" -gt 0 ]; do
    case "$1" in
      sudo|doas|env|command|nice|time|nohup|stdbuf) shift ;;
      *=*) shift ;;
      -*) shift ;;
      *) break ;;
    esac
  done
  [ "${1:-}" = "git" ] || return 0
  shift

  local cpath="" tok
  while [ "$#" -gt 0 ]; do
    tok="$1"
    shift
    case "$tok" in
      -C|--git-dir)
        if [ "$#" -gt 0 ]; then cpath="$1"; shift; fi ;;
      --git-dir=*) cpath="${tok#--git-dir=}" ;;
      -C?*) cpath="${tok#-C}" ;;
      --work-tree|--namespace|--super-prefix|-c|--config-env)
        if [ "$#" -gt 0 ]; then shift; fi ;;
      -*) : ;;
      *)
        # First bareword after the git-level options is the subcommand.
        if [ "$tok" = "$want" ]; then
          # shellcheck disable=SC2034  # read by the sourcing gate, not here
          GIT_CMD_CPATH[$GIT_CMD_N]="$cpath"
          # shellcheck disable=SC2034
          GIT_CMD_ARGS[$GIT_CMD_N]="$*"
          GIT_CMD_N=$((GIT_CMD_N + 1))
        fi
        return 0 ;;
    esac
  done
  return 0
}

# Find every invocation of <subcommand> in a command string. Sets:
#   GIT_CMD_N          how many were found (0 = not present, gate should exit 0)
#   GIT_CMD_CPATH[i]   -C / --git-dir path of invocation i, "" when absent
#   GIT_CMD_ARGS[i]    arguments after the subcommand, space-joined
git_cmd_scan() { # git_cmd_scan <subcommand> <command-string>
  local want="$1" cmdstr="$2" line
  GIT_CMD_N=0
  # shellcheck disable=SC2034  # both are read by the sourcing gate, not here
  GIT_CMD_CPATH=()
  # shellcheck disable=SC2034
  GIT_CMD_ARGS=()

  local -a toks=()
  # Heredoc rather than a pipe: the loop must run in THIS shell so the globals
  # above survive it.
  while IFS= read -r line; do
    case "$line" in
      S)
        [ "${#toks[@]}" -eq 0 ] || _git_cmd_segment "$want" "${toks[@]}"
        toks=() ;;
      T*)
        toks[${#toks[@]}]="${line#T}" ;;
    esac
  done <<EOF
$(printf '%s' "$cmdstr" | _git_cmd_tokenize)
EOF
  [ "${#toks[@]}" -eq 0 ] || _git_cmd_segment "$want" "${toks[@]}"
  return 0
}

# Resolve the repo an invocation targets: its -C/--git-dir path, else a leading
# `cd <path> &&`, else the session cwd, else the project dir. Prints the path;
# returns 1 when none of them is a git repo, which every gate treats as
# "cannot determine" and never blocks on.
git_cmd_repo() { # git_cmd_repo <cpath> <command-string>
  local target="$1" cmdstr="$2" cand
  if [ -z "$target" ]; then
    target=$(printf '%s\n' "$cmdstr" | sed -n '1s/^cd[[:space:]]\{1,\}"\([^"]*\)"[[:space:]]*&&.*/\1/p')
    [ -n "$target" ] || target=$(printf '%s\n' "$cmdstr" | sed -n "1s/^cd[[:space:]]\{1,\}'\([^']*\)'[[:space:]]*&&.*/\1/p")
    [ -n "$target" ] || target=$(printf '%s\n' "$cmdstr" | sed -n '1s/^cd[[:space:]]\{1,\}\([^[:space:]]*\)[[:space:]]*&&.*/\1/p')
  fi
  # An unexpanded variable in the path cannot be resolved here.
  case "$target" in *'$'*) target="" ;; esac

  for cand in "$target" "$PWD" "${CLAUDE_PROJECT_DIR:-}"; do
    [ -n "$cand" ] || continue
    [ -d "$cand" ] || continue
    if git -C "$cand" rev-parse --show-toplevel >/dev/null 2>&1; then
      printf '%s\n' "$cand"
      return 0
    fi
  done
  return 1
}

# Does one `git push` invocation publish new code? Deletion-only pushes and
# tag-only pushes do not. `--follow-tags` DOES: it pushes the current branch
# plus its reachable annotated tags — treating it as tag-only let a default-branch
# push skip every gate. Subshell body so `set -f` cannot leak: a refspec like
# `+refs/*` must not glob against the cwd.
git_push_publishes_code() ( # git_push_publishes_code <args-of-one-push>
  set -f
  seen_remote=0
  colon_deletes=0
  other_refspecs=0
  tags_only=0
  explicit_delete=0
  skip_next=0
  for tok in $1; do
    if [ "$skip_next" = 1 ]; then skip_next=0; continue; fi
    case "$tok" in
      --delete|-d) explicit_delete=1 ;;
      --tags) tags_only=1 ;;
      -o|--push-option|--repo|--receive-pack|--exec) skip_next=1 ;;
      --*=*) : ;;
      -*) : ;;
      :*) colon_deletes=1 ;;
      *) if [ "$seen_remote" -eq 0 ]; then seen_remote=1; else other_refspecs=1; fi ;;
    esac
  done
  [ "$explicit_delete" -eq 1 ] && exit 1
  [ "$colon_deletes" -eq 1 ] && [ "$other_refspecs" -eq 0 ] && exit 1
  [ "$tags_only" -eq 1 ] && [ "$other_refspecs" -eq 0 ] && exit 1
  exit 0
)
