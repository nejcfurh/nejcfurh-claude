# nejcfurh-claude

Personal **global** Claude Code configuration — rules, skills, agents, hooks, and settings that apply to every project. Clone on any machine, run one script, and `~/.claude` is live.

## Install

On a fresh machine, install Claude Code itself via the native installer (NOT `npm install -g` — an npm install lives inside whichever node version is active and breaks when nvm switches):

```bash
curl -fsSL https://claude.ai/install.sh | bash
# ensure ~/.local/bin precedes nvm in PATH (in ~/.zshrc, before the nvm loader):
# export PATH="$HOME/.local/bin:$PATH"
```

Then this config:

```bash
git clone git@github.com:nejcfurh/nejcfurh-claude.git && cd nejcfurh-claude
bash scripts/setup.sh --check   # dry-run
bash scripts/setup.sh           # symlink into ~/.claude + install refactoring-ui plugin
```

Everything is symlinked, so edits in `~/.claude` and in the repo are the same files — commit when it stabilizes. Existing files are backed up to `<path>.bak.<timestamp>`. Machine-local overrides (env vars, experiments) go in `~/.claude/settings.local.json`, which is never symlinked or committed.

## What's inside

| Path | Contents |
| --- | --- |
| `CLAUDE.md` | Core global rules: priority order, workflow, behavioral rules, security, environment |
| `rules/` | Auto-loaded conventions: communication, comments, git, typescript, tests, engineering principles, context7 |
| `skills/` | Workflow: `grill`, `build`, `ship`, `debug`, `test`, `prune`, `spec`, `review-pr`, `address-pr-comment`, `commit`, `pr`, `rebase`, `handoff`, `verify-frontend-change`, `retro` · Docs: `context7-mcp`, `find-docs`, `review-code` · Design (Emil Kowalski): `emil-design-eng`, `apple-design`, `animation-vocabulary`, `find-animation-opportunities`, `improve-animations`, `review-animations` |
| `commands/` | `/verify-done` — discover what CI runs and run exactly that |
| `agents/` | Opt-in subagent personas — see [Personas](#personas) |
| `hooks/` | Full quality gates (see below) |
| `scripts/` | `setup.sh`, `statusline.sh`, `notify.sh`, `chime.sh` (Stop/Notification sound), `detect-parent-branch.sh` (stacked-PR base detection) |
| `tests/` | Regression suites for every hook and script with gate logic — `bash tests/run-all.sh` |
| `settings.json` | ~100-rule security deny-list, hook wiring, plugins, statusline |

## Workflow (lightweight by default)

1. **Understand** — check how the codebase already solves similar problems.
2. **Align** — plan for non-trivial work; `/grill <topic>` for large features and architectural decisions (interviews you one question at a time, writes CONTEXT.md terms and ADRs as decisions crystallize).
3. **Implement** — `/build` discipline: small increments, continuous typecheck/tests, atomic commits.
4. **Verify** — `/verify-done` before every push (hooks enforce it at push time anyway).

Trivial changes (typos, one-liners, version bumps) skip everything.

## Loops

Verification skills + hooks are the foundation; Claude Code's loop primitives build on them:

| Loop | Reach for | Example |
| --- | --- | --- |
| Turn-based | Verification skills | `/verify-done`, `verify-frontend-change` run inside every turn |
| Goal-based | `/goal` + deterministic criteria | `/goal all /verify-done checks pass, stop after 5 tries` |
| Time-based | `/loop` / `/schedule` | `/loop 5m check my PR, address review comments, fix failing CI` |

No custom CI-watcher machinery needed — `/loop` covers PR babysitting natively, and the hooks (typecheck, test, push gates) fire inside every loop iteration, so loops can't hand back unverified work.

## Personas

Domain-expert subagents, spawned via the Agent tool for substantial work in their domain (skipped for trivial changes). `/grill` can convene them as a read-only panel for cross-domain plans; `/review-pr` offers them for specialist review passes. Deliberately lean: concrete guardrails and red flags only, no role-play filler.

| Persona | Use for | Signature guardrails |
| --- | --- | --- |
| `frontend-staff-engineer` | React / React Native / Next.js architecture, state management, Core Web Vitals, accessibility | No `useEffect` for derived state, no index-as-key, image dimensions (CLS), focus-trapped modals, semantic HTML |
| `backend-staff-engineer` | NestJS/Node APIs (REST, GraphQL, WebSocket), event-driven systems, caching, resilience, observability | Idempotency on every retry, DLQ on every consumer, timeouts on every outbound call, correlation IDs, graceful shutdown |
| `cybersecurity-expert` | Security reviews, threat modeling, auth design (OAuth/JWT/sessions), vulnerability analysis, dependency audits | Parameterized queries, no JWT in localStorage, bcrypt cost ≥ 12, magic-byte upload validation, SSRF allowlists |
| `database-master` | PostgreSQL (deep) + MySQL, MongoDB, Redis — modeling, query optimization, indexing, zero-downtime migrations | EXPLAIN-backed claims, keyset pagination, `CREATE INDEX CONCURRENTLY`, ESR index rule (Mongo), TTLs everywhere (Redis), pick the store for the workload |
| `product-manager` | MVP/v1 scoping, "should we build this", feature planning, scope-creep review | Riskiest assumption first, kill-criterion before first commit, no settings screens in v1, every cut gets a revival trigger, walking skeleton over breadth |
| `ai-engineer` | LLM features, agents, tool-calling flows, eval design, prompt pipelines | No agent feature without an eval set, outcome + trajectory graded separately, idempotency keys on mutating tools, preconditions on writes, single-writer state, tool-level gates over prompt pleading |

## Hooks (full gates)

| Hook | Fires on | Does |
| --- | --- | --- |
| `auto-format.sh` | file edit | Biome/Prettier format |
| `post-edit-typecheck.sh` | .ts/.tsx edit | typecheck + lint |
| `pre-commit-branch-gate.sh` | git commit | blocks commits on main/master |
| `pre-commit-coauthor-gate.sh` | git commit | blocks Co-Authored-By / AI attribution |
| `pre-commit-conventional-gate.sh` | git commit | enforces conventional commits |
| `pre-git-state-refresh.sh` | git/gh writes | injects ground-truth PR state |
| `pre-pr-test-gate.sh` | gh pr create | tests must pass |
| `pre-push-gate.sh` | git push | lint + typecheck + test + build |
| `symlink-check.sh` | session start | warns on symlink drift |

All hooks detect the package manager from the lockfile (bun/pnpm/yarn/npm) and have `SKIP_*` env bypasses for emergencies. The commit gates match both `git commit` and cross-repo forms (`git -C <path> commit`, `cd <path> && git commit`) and gate on the branch of the repo the commit actually targets. Every gate has a regression suite in `tests/` (`bash tests/run-all.sh`).

## Licensing

[MIT](LICENSE) — reuse freely. Vendored/adapted third-party material is MIT-licensed and credited in [NOTICE.md](NOTICE.md). The refactoring-ui plugin is installed from its source repo at setup time rather than vendored, because its upstream LICENSE is all-rights-reserved and forbids redistribution. Machine- or employer-specific settings (work plugins, internal permissions) belong in `~/.claude/settings.local.json`, which is never committed.
