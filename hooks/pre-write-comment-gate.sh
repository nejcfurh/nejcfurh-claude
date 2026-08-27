#!/usr/bin/env bash
# PreToolUse (Write|Edit): block a prose code comment when the target repo's own
# instructions ban comments.
#
# Some codebases prohibit comments outright. The rule is unambiguous and still
# gets violated, because the urge to leave a short rationale for the next reader
# arrives exactly when the code is subtle — which is when the prohibition is
# least intuitive and most deliberate. Attention is not the lever here; a gate
# is. The rationale belongs in the PR description, where it stays with the change.
#
# Nothing about any single project is encoded here: the gate reads the nearest
# CLAUDE.md up-tree and fires only if that file states the prohibition itself.
#
# Deliberately narrow. It fires only when ALL of these hold:
#   - the target is a JS/TS-family source file
#   - the nearest CLAUDE.md at or above it prohibits comments
#   - the write introduces a comment line that was not already there
#     (Edit: absent from old_string; Write: absent from the file on disk)
#   - the line is prose, not a tooling directive (@ts-, eslint-, <reference, …)
# so it stays silent on repos with no such rule, on edits that merely carry an
# existing comment along, and on the pragmas that have to be comments.
#
# Bypass: set SKIP_COMMENT_PROHIBITION_GATE to any non-empty value.

set -u

[ -n "${SKIP_COMMENT_PROHIBITION_GATE:-}" ] && exit 0

payload=$(cat 2>/dev/null) || exit 0
[ -n "$payload" ] || exit 0

command -v jq >/dev/null 2>&1 || exit 0

fp=$(printf '%s' "$payload" | jq -r '.tool_input.file_path // empty' 2>/dev/null) || exit 0
[ -n "$fp" ] || exit 0

case "$fp" in
  *.ts | *.tsx | *.mts | *.cts | *.js | *.jsx | *.mjs | *.cjs) : ;;
  *) exit 0 ;;
esac

dir=$(dirname "$fp")
[ -d "$dir" ] || exit 0

# Resolve both ends physically. git reports a resolved toplevel, so an unresolved
# $dir (macOS /var -> /private/var) never compares equal to it, the walk runs past
# the repo root, and a CLAUDE.md in some unrelated ancestor starts governing this
# file.
dir=$(cd "$dir" 2>/dev/null && pwd -P) || exit 0
[ -n "$dir" ] || exit 0

# Search up to the repo root, never past it: a parent directory outside the repo
# belongs to a different project whose rules do not govern this file.
top=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null) || exit 0
[ -n "$top" ] || exit 0
top=$(cd "$top" 2>/dev/null && pwd -P) || exit 0
[ -n "$top" ] || exit 0

# Phrasings that read as an instruction. Bare "no comments" is left out on
# purpose — "no comments needed for obvious code" is advice, not a prohibition.
PROHIBITION='do not comment|don.?t comment|write zero comments|zero comments|no code comments|never (write|add|leave) comments|comments are (banned|forbidden|prohibited|not allowed)|do not (write|add|leave) (any )?comments'

banned=""
d=$dir
while : ; do
  if [ -f "$d/CLAUDE.md" ] && grep -qiE "$PROHIBITION" "$d/CLAUDE.md" 2>/dev/null; then
    banned="$d/CLAUDE.md"
    break
  fi
  [ "$d" = "$top" ] && break
  parent=$(dirname "$d")
  [ "$parent" = "$d" ] && break
  d=$parent
done
[ -n "$banned" ] || exit 0

# Prose comment lines only, trimmed so re-indentation does not read as new.
comment_lines() {
  awk '
    {
      line = $0
      sub(/^[ \t]+/, "", line)
      sub(/[ \t\r]+$/, "", line)
      if (line ~ /^#!/) next
      if (line !~ /^\/\// && line !~ /^\/\*/ && line !~ /^\{\/\*/) next
      # Matched by SHAPE, not by a list of tool names: linter pragmas are
      # <tool>-disable / -enable / -ignore, so the shape covers every linter
      # including ones that do not exist yet, and the gate carries no opinion
      # about which toolchain a project uses.
      if (line ~ /^\/\/[ \t]*(@ts-|[a-z][a-z0-9]*-(disable|enable|ignore)|<reference|\/ *<reference|#(region|endregion)|(istanbul|c8|v8) ignore)/) next
      if (line ~ /^\/\*[ \t]*(@(__PURE__|license|preserve)|global |webpack[A-Za-z]+:|[a-z][a-z0-9]*-(disable|enable|ignore)|(istanbul|c8|v8) ignore)/) next
      if (line ~ /^\{\/\*[ \t]*[a-z][a-z0-9]*-(disable|enable|ignore)/) next
      print line
    }
  '
}

added=$(printf '%s' "$payload" | jq -r '.tool_input.new_string // .tool_input.content // empty' 2>/dev/null) || exit 0
[ -n "$added" ] || exit 0

baseline=$(printf '%s' "$payload" | jq -r '.tool_input.old_string // empty' 2>/dev/null) || baseline=""
# A Write carries no old_string: the file on disk is the baseline, and a file
# that does not exist yet has none, so every comment in it is new.
if [ -z "$baseline" ] && [ -f "$fp" ]; then
  baseline=$(cat "$fp" 2>/dev/null) || baseline=""
fi

new_comments=$(printf '%s\n' "$added" | comment_lines)
[ -n "$new_comments" ] || exit 0
base_comments=$(printf '%s\n' "$baseline" | comment_lines)

offending=""
count=0
# Process substitution, not a here-document: bash backs a heredoc with a temp
# file, and a hook that needs a writable temp dir fails open in exactly the
# sandboxed contexts it is supposed to run in. The loop stays in this shell so
# the counters survive it.
while IFS= read -r line; do
  [ -n "$line" ] || continue
  if [ -n "$base_comments" ] && printf '%s\n' "$base_comments" | grep -Fqx -- "$line"; then
    continue
  fi
  count=$((count + 1))
  [ -z "$offending" ] && offending="$line"
done < <(printf '%s\n' "$new_comments")

[ "$count" -gt 0 ] || exit 0

HELPER="$HOME/.claude/hooks/record-gate-block.sh"
[ -x "$HELPER" ] && "$HELPER" comment-prohibition "$payload" >/dev/null 2>&1

rel=${fp#"$top"/}
plural=""
[ "$count" -gt 1 ] && plural="s"

cat >&2 <<MSG
BLOCKED: this repo prohibits code comments, and this write adds $count.

  file: $rel
  rule: $banned
  line: $offending

Remove the comment$plural and write the write again. If the reasoning is worth
keeping, it belongs in the PR description, where it stays attached to the change
instead of accumulating in the file.

Tooling directives (@ts-expect-error, eslint-disable, /// <reference, …) are
already exempt. If this is a genuine false positive, set
SKIP_COMMENT_PROHIBITION_GATE=1 for the call.
MSG

exit 2
