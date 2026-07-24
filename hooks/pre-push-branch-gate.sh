#!/usr/bin/env bash
# PreToolUse (Bash, git push): block pushes that target the repo's DEFAULT
# branch, whatever it is named. Permission-rule globs can only string-match
# the literal word "main"; this gate resolves the actual push target — bare
# `git push` on the default branch, `HEAD`, refspecs, --all/--delete — and
# compares it against the branch origin/HEAD points at.
# Never blocks when the default branch cannot be determined.
# Bypass: set SKIP_PUSH_BRANCH_GATE to any non-empty value.

set -u

[ -n "${SKIP_PUSH_BRANCH_GATE:-}" ] && exit 0
command -v jq >/dev/null 2>&1 || exit 0

payload=$(cat 2>/dev/null) || exit 0
[ -n "$payload" ] || exit 0

cmd=$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null) || exit 0

# shellcheck source=hooks/git-cmd-lib.sh
. "$(dirname "$0")/git-cmd-lib.sh"

# Every `git … push` in the command, whatever git-level options precede it. The
# tokenizer handles backslash continuations and quoted spans itself, so a commit
# message mentioning `git push` stays data and does not reach this gate.
git_cmd_scan push "$cmd"
[ "$GIT_CMD_N" -gt 0 ] || exit 0

block() { # block <default-branch>
  "$(dirname "$0")/record-gate-block.sh" "pre-push-branch-gate" "$payload" 2>/dev/null || true
  {
    echo "Blocked: this push targets '$1' — the repo's default branch."
    echo "Push a feature branch and open a PR instead."
    echo "Bypass (human-only): '!'-prefix the command, or export SKIP_PUSH_BRANCH_GATE=1 in your shell."
  } >&2
  exit 2
}

# Judge EVERY push in the command, not just the first: only one invocation used
# to be parsed, so `git push origin feature && git push origin main` published
# the default branch entirely unchecked.
set -f   # a refspec like +refs/* must not glob against the cwd
i=0
while [ "$i" -lt "$GIT_CMD_N" ]; do
  args="${GIT_CMD_ARGS[$i]}"
  cpath="${GIT_CMD_CPATH[$i]}"
  i=$((i + 1))

  # Resolve the repo this push targets: `git -C <path>` or a leading
  # `cd <path> &&` wins over the cwd. Undeterminable -> cannot judge, skip.
  repo=$(git_cmd_repo "$cpath" "$cmd") || continue

  # The repo's default branch: origin/HEAD first, then well-known names.
  default=$(git -C "$repo" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||')
  if [ -z "$default" ]; then
    if git -C "$repo" rev-parse --verify --quiet origin/main >/dev/null; then
      default="main"
    elif git -C "$repo" rev-parse --verify --quiet origin/master >/dev/null; then
      default="master"
    fi
  fi
  [ -n "$default" ] || continue

  remote=""
  refspecs=""
  push_everything=0
  tags_only_hint=0
  skip_next=0
  for tok in $args; do
    if [ "$skip_next" = 1 ]; then skip_next=0; continue; fi
    case "$tok" in
      --all|--mirror|--branches) push_everything=1 ;;
      # --follow-tags pushes the CURRENT BRANCH plus its annotated tags, so it is
      # not a tag-only push. Exempting it let a default-branch push through.
      --tags) tags_only_hint=1 ;;
      -o|--push-option|--repo|--receive-pack|--exec) skip_next=1 ;;
      --*=*) : ;;
      -*) : ;;
      *)
        if [ -z "$remote" ]; then remote="$tok"; else refspecs="$refspecs $tok"; fi
        ;;
    esac
  done

  # Collect the branches this push would update on the remote.
  targets=""
  if [ "$push_everything" = 1 ]; then
    targets="$default"
  elif [ -n "$refspecs" ]; then
    for rs in $refspecs; do
      rs="${rs#+}"
      dst="${rs#*:}"                       # dst of src:dst; the whole spec if no colon
      [ -n "$dst" ] || continue            # "branch:" — nothing to update
      case "$dst" in
        refs/heads/*) dst="${dst#refs/heads/}" ;;
        refs/*) continue ;;                # tags/notes/etc — not a branch push
      esac
      if [ "$dst" = "HEAD" ]; then
        dst=$(git -C "$repo" branch --show-current 2>/dev/null)
      fi
      targets="$targets $dst"
    done
  elif [ "$tags_only_hint" = 0 ]; then
    # Bare `git push` (or `git push <remote>`): pushes the current branch.
    targets=$(git -C "$repo" branch --show-current 2>/dev/null)
  fi

  for t in $targets; do
    [ -n "$t" ] || continue
    if [ "$t" = "$default" ]; then
      block "$default"
    fi
  done
done
set +f

exit 0
