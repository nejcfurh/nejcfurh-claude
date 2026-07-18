#!/usr/bin/env bash
# PostToolUse (Write|Edit): format the edited file with biome or prettier,
# whichever config is found nearest when walking up from the file's directory.
# This hook never blocks - every code path exits 0.

set -u

command -v jq >/dev/null 2>&1 || exit 0

payload=$(cat 2>/dev/null) || exit 0
[ -n "$payload" ] || exit 0

file=$(printf '%s' "$payload" | jq -r '.tool_input.file_path // empty' 2>/dev/null) || exit 0
[ -n "$file" ] || exit 0
[ -f "$file" ] || exit 0

# Only format known source/config/doc extensions.
case "$file" in
  *.ts|*.tsx|*.js|*.jsx|*.mjs|*.cjs|*.json|*.css|*.scss|*.md|*.html|*.yml|*.yaml) : ;;
  *) exit 0 ;;
esac

# Never touch vendored code.
case "$file" in
  *node_modules*) exit 0 ;;
esac

# Never touch lockfiles.
base=$(basename "$file")
case "$base" in
  package-lock.json|yarn.lock|pnpm-lock.yaml|bun.lock|bun.lockb) exit 0 ;;
esac

dir=$(cd "$(dirname "$file")" 2>/dev/null && pwd) || exit 0

# Walk up from the file's directory looking for a formatter config.
# Biome wins over prettier when both exist in the same directory.
formatter=""
cfg_dir=""
d="$dir"
while :; do
  if [ -f "$d/biome.json" ] || [ -f "$d/biome.jsonc" ]; then
    formatter="biome"; cfg_dir="$d"; break
  fi
  if [ -f "$d/.prettierrc" ] || [ -f "$d/.prettierrc.json" ] || [ -f "$d/.prettierrc.js" ] \
    || [ -f "$d/prettier.config.js" ] || [ -f "$d/prettier.config.mjs" ]; then
    formatter="prettier"; cfg_dir="$d"; break
  fi
  [ "$d" = "/" ] && break
  [ "$d" = "$HOME" ] && break
  d=$(dirname "$d")
done

[ -n "$formatter" ] || exit 0

case "$formatter" in
  biome)
    ( cd "$cfg_dir" && npx --no-install @biomejs/biome format --write "$file" ) >/dev/null 2>&1 \
      || ( cd "$cfg_dir" && biome format --write "$file" ) >/dev/null 2>&1 \
      || true
    ;;
  prettier)
    ( cd "$cfg_dir" && npx --no-install prettier --write "$file" ) >/dev/null 2>&1 || true
    ;;
esac

exit 0
