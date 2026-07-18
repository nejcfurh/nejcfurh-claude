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
builtins="config fast clear help compact sandbox loop goal schedule workflows remember init review security-review code-review simplify verify run fewer-permission-prompts"
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
