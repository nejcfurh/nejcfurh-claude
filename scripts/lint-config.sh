#!/usr/bin/env bash
# Lint this config repo itself: hook wiring, script health, skill/agent
# frontmatter, and dead slash-command references in the rule files.
# Run from anywhere: bash scripts/lint-config.sh
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
errors=0

err() {
  echo "FAIL: $1"
  errors=$((errors + 1))
}

ok() {
  echo "  ok: $1"
}

echo "== settings.json"
if ! jq -e . "$REPO/settings.json" >/dev/null 2>&1; then
  err "settings.json is not valid JSON"
else
  ok "valid JSON"
fi

echo "== hook wiring"
# Every hooks/<name>.sh referenced in settings.json must exist and be executable.
refs=$(jq -r '.. | .command? // empty' "$REPO/settings.json" \
  | grep -oE '\$HOME/\.claude/(hooks|scripts)/[A-Za-z0-9._-]+\.sh' \
  | sed 's|\$HOME/\.claude/||' | sort -u)
while IFS= read -r ref; do
  [ -n "$ref" ] || continue
  if [ ! -f "$REPO/$ref" ]; then
    err "settings.json references $ref, which does not exist in the repo"
  elif [ ! -x "$REPO/$ref" ]; then
    err "$ref is referenced by settings.json but not executable"
  else
    ok "$ref"
  fi
done <<EOF
$refs
EOF

echo "== shell script syntax + executable bits"
for f in "$REPO"/hooks/*.sh "$REPO"/scripts/*.sh "$REPO"/tests/*.sh; do
  rel="${f#"$REPO"/}"
  if ! bash -n "$f" 2>/dev/null; then
    err "$rel fails bash -n"
  fi
  case "$rel" in
    hooks/*|scripts/*)
      [ -x "$f" ] || err "$rel is not executable"
      ;;
  esac
done
ok "bash -n + executable bits checked"

echo "== setup.sh / symlink-check.sh item coverage"
# Every top-level config entry Claude Code consumes must be symlinked by
# setup.sh and watched by symlink-check.sh — a new directory that is not
# listed silently never reaches ~/.claude. setup.sh may list EXTRA items
# (tombstones that clean up dangling links); symlink-check.sh must not.
setup_items=$(sed -n '/^ITEMS=(/,/^)/p' "$REPO/scripts/setup.sh" | grep -oE '"[^"]+"' | tr -d '"' | tr '\n' ' ')
check_items=$(grep -m1 '^ITEMS=' "$REPO/hooks/symlink-check.sh" | sed 's/^ITEMS="//; s/"$//')
expected="CLAUDE.md settings.json"
for d in "$REPO"/*/; do
  d=$(basename "$d")
  # plugins/ ships through the repo's marketplace, never a symlink:
  # ~/.claude/plugins is Claude Code's own install cache.
  case "$d" in tests|vendor|node_modules|plugins) continue ;; esac
  expected="$expected $d"
done
for item in $expected; do
  case " $setup_items " in
    *" $item "*) : ;;
    *) err "$item exists in the repo but is missing from ITEMS in scripts/setup.sh" ;;
  esac
  case " $check_items " in
    *" $item "*) : ;;
    *) err "$item exists in the repo but is missing from ITEMS in hooks/symlink-check.sh" ;;
  esac
done
for item in $check_items; do
  case " $expected " in
    *" $item "*) : ;;
    *) err "hooks/symlink-check.sh watches '$item', which no longer exists in the repo" ;;
  esac
done
ok "setup/symlink-check items checked"

echo "== plugin marketplace wiring"
# A plugin folder reaches a machine only when the marketplace lists it and
# settings.json both declares that marketplace and enables the plugin; any one
# missing installs nothing and says nothing.
marketplace="$REPO/.claude-plugin/marketplace.json"
if [ ! -d "$REPO/plugins" ]; then
  ok "no plugins/"
elif ! jq -e . "$marketplace" >/dev/null 2>&1; then
  err ".claude-plugin/marketplace.json is missing or not valid JSON"
else
  mp_name=$(jq -r '.name' "$marketplace")
  jq -e --arg m "$mp_name" '.extraKnownMarketplaces[$m]' "$REPO/settings.json" >/dev/null 2>&1 \
    || err "settings.json extraKnownMarketplaces does not declare '$mp_name'"
  for p in "$REPO"/plugins/*/; do
    p=$(basename "$p")
    manifest="$REPO/plugins/$p/.claude-plugin/plugin.json"
    if [ "$(jq -r '.name' "$manifest" 2>/dev/null)" != "$p" ]; then
      err "plugins/$p/.claude-plugin/plugin.json is missing, invalid, or names another plugin"
    fi
    jq -e --arg n "$p" --arg s "./plugins/$p" '.plugins[] | select(.name == $n and .source == $s)' "$marketplace" >/dev/null 2>&1 \
      || err "plugins/$p is not listed in .claude-plugin/marketplace.json with source ./plugins/$p"
    jq -e --arg k "$p@$mp_name" '.enabledPlugins[$k] == true' "$REPO/settings.json" >/dev/null 2>&1 \
      || err "settings.json enabledPlugins does not enable $p@$mp_name"
  done
  while IFS= read -r src; do
    [ -n "$src" ] || continue
    [ -d "$REPO/$src" ] || err "marketplace.json lists $src, which does not exist in the repo"
  done <<EOF
$(jq -r '.plugins[].source' "$marketplace")
EOF
  ok "plugin marketplace wiring checked"
fi

echo "== skill frontmatter"
for f in "$REPO"/skills/*/SKILL.md; do
  rel="${f#"$REPO"/}"
  head -20 "$f" | grep -q '^name:' || err "$rel missing 'name:' frontmatter"
  head -20 "$f" | grep -q '^description:' || err "$rel missing 'description:' frontmatter"
done
ok "skills checked"

echo "== agent frontmatter"
for f in "$REPO"/agents/*.md; do
  rel="${f#"$REPO"/}"
  head -20 "$f" | grep -q '^name:' || err "$rel missing 'name:' frontmatter"
  head -20 "$f" | grep -q '^description:' || err "$rel missing 'description:' frontmatter"
done
ok "agents checked"

echo "== dead slash-command references"
# Slash commands mentioned in the rule files must resolve to a skill, a
# command, or a known built-in/plugin — otherwise the docs promise something
# the config no longer ships.
builtins="config model fast clear help compact sandbox loop goal schedule workflows remember init review security-review code-review simplify verify run fewer-permission-prompts"
mentions=$(grep -ohE '(^|[[:space:]`(])/[a-z][a-z0-9-]+' \
  "$REPO/CLAUDE.md" "$REPO"/rules/*.md "$REPO/README.md" 2>/dev/null \
  | sed 's|.*/||' | sort -u)
while IFS= read -r name; do
  [ -n "$name" ] || continue
  if [ -d "$REPO/skills/$name" ] || [ -f "$REPO/commands/$name.md" ]; then
    continue
  fi
  case " $builtins " in
    *" $name "*) continue ;;
  esac
  err "reference to /$name (in CLAUDE.md / rules/ / README.md) resolves to no skill, command, or known built-in"
done <<EOF
$mentions
EOF
ok "references checked"

echo ""
if [ "$errors" -eq 0 ]; then
  echo "Config lint passed."
  exit 0
fi
echo "Config lint FAILED: $errors problem(s)."
exit 1
