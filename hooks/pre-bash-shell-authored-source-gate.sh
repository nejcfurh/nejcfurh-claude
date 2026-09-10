#!/usr/bin/env bash
# PreToolUse (Bash): warn when a shell command authors a source file, because
# whatever the project hangs off the editing tools did not see it.
#
# Projects routinely run a formatter, linter or codegen step on Edit/Write tool
# calls. A heredoc, a `>` redirect or an inline python/node script writing the
# same path is invisible to that, so the file lands unformatted and the omission
# surfaces much later — at a pre-push gate or in CI, on a branch that looked
# clean. The failure is cheap to prevent and annoying to diagnose, because by
# then the diff has moved on.
#
# Narrow by design. It fires only for source extensions a formatter would touch,
# and never for scratch paths — temp dirs are where throwaway scripts belong and
# a gate that fires on those is noise.
#
# Non-blocking: authoring through the shell is often the right call (generated
# files, large payloads, avoiding a read-before-edit round trip). The point is to
# run the formatter afterwards, not to avoid the redirect.
#
# Bypass: set SKIP_SHELL_AUTHORED_SOURCE_GATE to any non-empty value.

set -u

[ -n "${SKIP_SHELL_AUTHORED_SOURCE_GATE:-}" ] && exit 0

payload=$(cat 2>/dev/null) || exit 0
[ -n "$payload" ] || exit 0

# Runs on every Bash call, so bail on the common case with a builtin before
# spending a jq. No redirect and no heredoc means it cannot match.
case "$payload" in
  *'>'* | *'<<'* | *write_text* | *writeFileSync*) : ;;
  *) exit 0 ;;
esac

command -v jq >/dev/null 2>&1 || exit 0

cmd=$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null) || exit 0
[ -n "$cmd" ] || exit 0

src_ext='\.(ts|tsx|js|jsx|mjs|cjs|css|scss|vue|svelte)'
# The extension must end where it ends: unbounded, `\.js` also matches `.json`
# and `\.ts` matches `.tsv`, which fires on ordinary data-file redirects.
bound='([^A-Za-z0-9]|$)'

# A redirect or heredoc whose target is a source file, or an inline script
# writing one. Anything else is not authoring source through the shell.
# Both argument orders count: `writeFileSync('a.ts', …)` puts the path inside
# the call, `Path('a.ts').write_text(…)` puts it before the call.
# The heredoc delimiter must follow its `<<` immediately: allowing space there
# makes `grep '^<<<<<<<' some/file.ts` — hunting merge-conflict markers — read
# as a heredoc, which was every false positive in a 6969-command replay.
printf '%s' "$cmd" | grep -Eq \
  "(>>?[[:space:]]*[^[:space:]|]*${src_ext}${bound}|<<[-]?['\"]?[A-Za-z_][A-Za-z0-9_]*.*${src_ext}${bound}|(write_text|writeFileSync)[[:space:]]*\\([^)]*${src_ext}${bound}|${src_ext}['\"]*\\)[[:space:]]*\\.[[:space:]]*write_text)" \
  || exit 0

# Scratch paths are the legitimate home for throwaway scripts.
printf '%s' "$cmd" | grep -Eq '(/tmp/|/private/tmp/|\$TMPDIR|/scratchpad/|\.log\b)' && exit 0

cat <<'EOF'
[shell-authored-source] This writes a source file from the shell, so anything
the project runs on Edit/Write (formatter, linter, codegen) did not see it.
Run the project's formatter over the file before staging it, or author it with
Edit/Write instead. A file that skips the on-edit hook typically fails the
format check at the pre-push gate or in CI, long after the change is out of mind.
EOF
exit 0
