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

# Emit one line per token, prefixed "T", plus a marker line at each command
# separator found OUTSIDE quotes: "S" for ; & | newline, "O" where a subshell or
# group opens ( or {, "R" where one closes ) or }. A character state machine is
# the only way to know whether a `;` or the word `git` is code or data — the
# substring matches this replaces could not tell, which is why a commit message
# mentioning "git push" used to put a command through the push gates.
#
# Grouping characters are separators so the command word is reachable: without
# that, `(git commit -m x)` tokenizes its first word as "(git", `$(git push)` as
# "$(git", and `{ git commit; }` starts with "{" — none of which equal "git", so
# all three slipped past every gate. The cost is that an UNQUOTED brace or paren
# inside an argument splits it (`--format=%(refname)`); that garbles args for
# subcommands the gates do not parse, and never hides a command word.
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
          if (c == "(" || c == "{") {
            if (have) { print "T" tok; tok = ""; have = 0 }
            print "O"; continue
          }
          if (c == ")" || c == "}") {
            if (have) { print "T" tok; tok = ""; have = 0 }
            print "R"; continue
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
# <cwd> is the directory a preceding `cd` put this segment in, used when the
# invocation names no -C/--git-dir of its own.
_git_cmd_segment() { # _git_cmd_segment <want> <cwd> <token…>
  local want="$1" cwd="$2"
  shift 2

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
          [ -n "$cpath" ] || cpath="$cwd"
          # shellcheck disable=SC2034  # read by the sourcing gate, not here
          GIT_CMD_CPATH[$GIT_CMD_N]="$cpath"
          # Newline-joined, not space-joined: no token can contain a newline (the
          # tokenizer turns one inside a quote into a space), so this is lossless
          # and a multi-word value like a commit message keeps its boundary.
          local oldifs="$IFS"
          IFS='
'
          # shellcheck disable=SC2034
          GIT_CMD_ARGS[$GIT_CMD_N]="$*"
          IFS="$oldifs"
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
  # `cd <path> &&` moves the directory the following commands run in, so a git
  # invocation naming no -C inherits it. The stack scopes that to the group it
  # happened in: without it, `(cd other && git status); git commit` would judge
  # the commit against `other` — a false ALLOW, worse than the missed cd it fixes.
  local -a cdstack=()
  local cdctx="" n
  # Heredoc rather than a pipe: the loop must run in THIS shell so the globals
  # above survive it.
  while IFS= read -r line; do
    case "$line" in
      T*) toks[${#toks[@]}]="${line#T}"; continue ;;
    esac
    if [ "${#toks[@]}" -gt 0 ]; then
      _git_cmd_segment "$want" "$cdctx" "${toks[@]}"
      if [ "${toks[0]}" = "cd" ] && [ -n "${toks[1]:-}" ]; then
        cdctx="${toks[1]}"
      fi
      toks=()
    fi
    case "$line" in
      O) cdstack[${#cdstack[@]}]="$cdctx" ;;
      R)
        n=${#cdstack[@]}
        if [ "$n" -gt 0 ]; then
          cdctx="${cdstack[$((n - 1))]}"
          unset "cdstack[$((n - 1))]"
        fi
        ;;
    esac
  done <<EOF
$(printf '%s' "$cmdstr" | _git_cmd_tokenize)
EOF
  [ "${#toks[@]}" -eq 0 ] || _git_cmd_segment "$want" "$cdctx" "${toks[@]}"
  return 0
}

# Resolve the repo an invocation targets: its -C/--git-dir path, else a leading
# `cd <path> &&`, else the session cwd, else the project dir. Prints the path;
# returns 1 when none of them is a git repo, which every gate treats as
# "cannot determine" and never blocks on.
git_cmd_repo() { # git_cmd_repo <cpath>
  local target="$1" cand
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

# The message a `git commit` invocation carries, printed on stdout; returns 1
# when it names none. Handles every spelling git accepts: `-m X`, `-mX`,
# `-am X`, `-amX`, `--message X`, `--message=X`.
#
# The gate this replaces matched only `-m "…"` / `-m '…'` with sed, so
# `--message="wip"`, `-am "wip"`, `-m wip` and `-mwip` all extracted nothing —
# and the gate treats "no subject" as a parse failure and allows the commit.
git_commit_message() { # git_commit_message <args-of-one-commit>
  local args="$1" tok want=0
  while IFS= read -r tok; do
    if [ "$want" -eq 1 ]; then
      printf '%s\n' "$tok"
      return 0
    fi
    case "$tok" in
      --message=*) printf '%s\n' "${tok#--message=}"; return 0 ;;
      --message|-m) want=1 ;;
      -m?*) printf '%s\n' "${tok#-m}"; return 0 ;;
      # Combined short flags ending in m: -am, -sm, -asm. The character class
      # keeps `--amend` (two dashes) out, which must not read as a message.
      -[a-zA-Z]*m) want=1 ;;
      -[a-zA-Z]*m?*) printf '%s\n' "${tok#*m}"; return 0 ;;
    esac
  done <<EOF
$args
EOF
  return 1
}

# Does a `git commit` invocation reuse an existing message (-c/-C <commit>)?
# Checked over tokens, not raw text: grepping the command for `-[Cc]` matched the
# flag inside a message like -m "fix: pass -c to jq" and skipped the gate.
git_commit_reuses_message() { # git_commit_reuses_message <args-of-one-commit>
  local args="$1" tok
  while IFS= read -r tok; do
    case "$tok" in
      -c|-C|-c?*|-C?*|--reuse-message|--reuse-message=*|--reedit-message|--reedit-message=*)
        return 0 ;;
    esac
  done <<EOF
$args
EOF
  return 1
}

# The commits one `git push` invocation would publish, one SHA per line.
#
# The gates used to compare the verify marker against `git rev-parse HEAD` and
# scan `HEAD --not --remotes` for foreign authors, regardless of what the command
# actually pushed. From a checkout of feat/a, `git push origin other` published a
# never-verified — and never author-checked — branch with the gates satisfied by
# HEAD. Resolve the SOURCE side of each refspec instead.
#
# Empty output means undeterminable; callers fall back to HEAD and never block on
# it. Subshell body so `set -f` cannot leak (a refspec may contain *).
git_push_source_shas() ( # git_push_source_shas <args-of-one-push> <repo>
  set -f
  args="$1"
  repo="$2"
  seen_remote=0
  refspecs=""
  push_all=0
  skip_next=0
  for tok in $args; do
    if [ "$skip_next" = 1 ]; then skip_next=0; continue; fi
    case "$tok" in
      --all|--mirror|--branches) push_all=1 ;;
      -o|--push-option|--repo|--receive-pack|--exec) skip_next=1 ;;
      --*=*) : ;;
      -*) : ;;
      *) if [ "$seen_remote" -eq 0 ]; then seen_remote=1; else refspecs="$refspecs $tok"; fi ;;
    esac
  done

  # --all/--mirror publish every local branch, so every branch tip counts.
  if [ "$push_all" -eq 1 ]; then
    git -C "$repo" for-each-ref --format='%(objectname)' refs/heads 2>/dev/null
    exit 0
  fi

  # Bare `git push` or `git push <remote>`: the current branch.
  if [ -z "$refspecs" ]; then
    git -C "$repo" rev-parse --verify --quiet HEAD 2>/dev/null
    exit 0
  fi

  for rs in $refspecs; do
    rs="${rs#+}"
    case "$rs" in
      :*) continue ;;              # deletion publishes nothing
      refs/tags/*) continue ;;     # tag ref, not a branch of code
    esac
    src="${rs%%:*}"                # src of src:dst; the whole spec when no colon
    [ -n "$src" ] || continue
    git -C "$repo" rev-parse --verify --quiet "${src}^{commit}" 2>/dev/null
  done
  exit 0
)

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
