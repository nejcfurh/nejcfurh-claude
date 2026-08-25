#!/usr/bin/env bash
# PreToolUse (Bash): warn when a production build is about to run while a dev
# server is listening, because most JS frameworks give both the same output dir.
#
# `next build` (webpack) and `next dev` (turbopack) both own `.next`; `vite
# build` and `vite dev` share `dist`/`.vite`. Running the build under a live dev
# server overwrites the manifests and chunks the running server is serving from,
# and the server does not notice: it keeps answering, but every route 500s. The
# failure looks nothing like its cause — you reach for the code you just changed,
# not the build you just ran — and recovering costs a restart plus whatever was
# in flight.
#
# The damage lands on whoever owns that server, which is frequently not you. A
# dev server you did not start is someone else's working state.
#
# Deliberately narrow. It fires only when BOTH hold:
#   - the command is a production build (not `dev`, not `start`, not `--watch`)
#   - something is actually listening on a common dev port
# so it stays silent on the ordinary case of building with nothing running.
#
# Non-blocking: sometimes overwriting the dir is exactly what you want (the dev
# server is yours and already dead). The fix is usually to stop the server, use a
# separate output dir, or build in a worktree — not to skip the build.
#
# Bypass: set SKIP_BUILD_DEV_SERVER_GATE to any non-empty value.

set -u

[ -n "${SKIP_BUILD_DEV_SERVER_GATE:-}" ] && exit 0

payload=$(cat 2>/dev/null) || exit 0
[ -n "$payload" ] || exit 0

# Runs on every Bash call, so bail on the cheap builtin before spending a jq.
case "$payload" in
  *build*) : ;;
  *) exit 0 ;;
esac

command -v jq >/dev/null 2>&1 || exit 0

cmd=$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null) || exit 0
[ -n "$cmd" ] || exit 0

# A production build, not a dev/watch invocation that legitimately shares the dir.
printf '%s' "$cmd" | grep -Eq \
  '(npm|yarn|pnpm|bun)[[:space:]]+run[[:space:]]+build|(npx[[:space:]]+)?(next|vite|nuxt|astro|remix|ng|expo)[[:space:]]+build|turbo[[:space:]]+run[[:space:]]+build' \
  || exit 0

# `--watch` / `dev` builds are the shared-dir case working as intended.
printf '%s' "$cmd" | grep -Eq -- '--watch|[[:space:]]dev([[:space:]]|$)' && exit 0

# Check the PORT, never a process name: dev servers run under `node` with argv
# that rarely contains the framework's name, so a pgrep miss reads as "nothing
# running" and the gate silently stops guarding.
command -v lsof >/dev/null 2>&1 || exit 0

listening=""
for port in ${BUILD_GATE_DEV_PORTS:-3000 3001 4200 5173 8080}; do
  if lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
    listening="$listening $port"
  fi
done

[ -n "$listening" ] || exit 0

cat <<EOF
[build-dev-server] A dev server is listening on:$listening — and a production
build usually writes to the SAME output dir the dev server is serving from
(\`.next\`, \`dist\`, \`.vite\`). Running the build now can leave that server
answering every route with a 500, with nothing in its log to explain why.

Before continuing, confirm whose server that is. If it is not yours, do not
overwrite it. Options: stop the server first, build in a separate worktree, or
point the build at its own output dir.
EOF
exit 0
