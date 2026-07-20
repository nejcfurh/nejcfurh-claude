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

Everything is symlinked, so edits in `~/.claude` and in the repo are the same files — commit when it stabilizes. Existing files are backed up to `<path>.bak.<timestamp>`. Machine-local overrides (env vars, experiments) go in `~/.claude/settings.local.json`, which is never symlinked or committed. The active `model` is per-machine runtime state — a git filter strips it from `settings.json` so it is never committed; set yours with `/model` or in `settings.local.json`.

Gate prerequisites: **`jq` is required** — every git gate parses its hook payload with it. Without jq, `setup.sh` aborts the install (pass `--allow-insecure-no-jq` to override) and the git-gate dispatcher fails **closed**, blocking every git command (`SKIP_GIT_GATE_NO_JQ=1` to bypass) rather than letting commands run ungated. `gitleaks` is recommended — without it the secret gate falls back to built-in patterns only.

## What's inside

| Path | Contents |
| --- | --- |
| `CLAUDE.md` | Core global rules: priority order, workflow, behavioral rules, security, environment |
| `rules/` | Auto-loaded conventions: communication, comments, git, typescript, tests, engineering principles, context7 |
| `skills/` | Workflow: `grill`, `build`, `verify-done`, `ship`, `debug`, `test`, `prune`, `spec`, `review-pr`, `address-pr-comment`, `commit`, `pr`, `rebase`, `handoff`, `verify-frontend-change`, `retro` · Docs: `context7-mcp`, `find-docs`, `review-code` · Design (Emil Kowalski): `emil-design-eng`, `apple-design`, `animation-vocabulary`, `find-animation-opportunities`, `improve-animations`, `review-animations` |
| `agents/` | Opt-in subagent personas — see [Personas](#personas) |
| `hooks/` | Full quality gates (see below) |
| `scripts/` | `setup.sh`, `statusline.sh`, `notify.sh`, `chime.sh` (Stop/Notification sound), `detect-parent-branch.sh` (stacked-PR base detection), `lint-config.sh` (CI lint of hook wiring, frontmatter, dead references) |
| `tests/` | Regression suites for every hook and script with gate logic — `bash tests/run-all.sh` (suites run concurrently, output printed in stable order) |
| `settings.json` | ~100-rule permission deny-list (Read/Edit tools + Bash command forms), OS-level sandbox `denyRead` for home credential stores, hook wiring, plugins, statusline |

**Secret-read boundary (scoped honestly).** The `Read`/`Edit` deny rules block those *tools* from touching `.env`, private keys, and cloud credentials — they do **not** constrain Bash, so `cat .env` still works. That is deliberate: local app runs (`npm run dev`) and "does this var exist" checks need project `.env` readable. Bash-level containment comes from the sandbox, not the deny-list: `sandbox.filesystem.denyRead` makes a handful of home credential stores (`~/.gnupg`, `~/.git-credentials`, `~/.netrc`, `~/.pypirc`, `~/.vault-token`) unreadable to every Bash subprocess at the OS level, and Bash network egress is restricted to an allowlist by the Claude Code sandbox **runtime** — not by anything in this repo's `settings.json` — which raises the cost of shipping a secret that *is* read to an arbitrary host. Treat that egress limit as a runtime-provided speed bump, not a guarantee this config makes: it depends on the sandbox behavior of your Claude Code version, so confirm it there rather than relying on it. `~/.ssh` and `~/.aws`/`gcloud` are intentionally left readable so `git push` and local cloud SDKs keep working — widen `denyRead` per-project in `settings.local.json` if a machine warrants it.

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

No custom CI-watcher machinery needed — `/loop` covers PR babysitting natively, and the push gates fire inside every loop iteration, so a loop won't *accidentally* hand back unverified work. These are cooperative guardrails, not an unbypassable boundary: the READY marker is a file the session itself can write, so they reliably catch the common accidental miss — not an agent set on routing around them. The marker is bound to the verified commit (see the push-gate rows below), which closes the stale-marker case but not the forge-it case.

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
| `git-gate-dispatch.sh` | any git command | the single PreToolUse entry for all git gates below: parses the payload once and routes by subcommand, so `git status` costs one process instead of ten; runs every gate from the payload's cwd, so `$PWD` fallbacks resolve the checkout the Bash tool is actually in (worktrees), not the session's start dir; runs `pre-git-state-refresh` last and only when nothing blocked; fails **closed** (blocks git) when `jq` is missing |
| `pre-git-meta-gate.sh` | any git command | runs first; blocks git meta-execution surfaces the subcommand gates can't see — `git -c <cfg>` / `--config-env` config injection (alias/pager/hooksPath → shell), `--exec-path` binary hijack, and `git diff --no-index` arbitrary-file reads. `git commit -c`, `-C <path>`, `--no-pager` stay allowed |
| `auto-format.sh` | file edit | Biome/Prettier format (local `node_modules/.bin` when present, npx fallback) |
| `invalidate-verify-marker.sh` | file edit | deletes the repo's `/verify-done` marker — checks that passed before an edit say nothing about the tree after it |
| `pre-commit-branch-gate.sh` | git commit | blocks commits on main/master |
| `pre-commit-coauthor-gate.sh` | git commit | blocks Co-Authored-By / AI attribution |
| `pre-commit-conventional-gate.sh` | git commit | enforces conventional commits |
| `pre-commit-secret-gate.sh` | git commit | secret scan of everything the commit could publish (staged, unstaged tracked, untracked) — gitleaks when installed plus built-in high-confidence patterns |
| `pre-git-state-refresh.sh` | git/gh writes | injects ground-truth PR state (cached ~60s per repo+branch — advisory context, no gate reads it) |
| `pre-merge-gate.sh` | gh | blocks `gh pr merge` (and the `gh api …/merge` fallback) — the user merges PRs manually |
| `pre-pr-test-gate.sh` | gh pr create | fallback test gate in the checkout the command targets: a fresh `/verify-done` READY marker whose recorded HEAD matches the current commit is trusted (tests already certified — no re-run); without a matching marker, tests must pass |
| `pre-push-branch-gate.sh` | git push | blocks pushes targeting the repo's default branch, whatever its name — bare `git push`, `HEAD`, refspecs, `--all`, `--delete` |
| `pre-push-author-gate.sh` | git push | blocks pushes whose outgoing commits carry a foreign author — fixture commits and tooling artifacts never ride along unnoticed |
| `pre-push-verify-gate.sh` | git push | requires a fresh `/verify-done` READY marker (`.git/verify-done-ok`) whose recorded HEAD matches the pushed commit — a later commit, amend, or rebase invalidates it (as does any edit); TTL backstop expires it; deletion-only (`--delete`, `:branch`) and tag-only pushes exempt |
| `pre-push-gate.sh` | git push | fallback suite in the checkout the push targets: a fresh `/verify-done` READY marker is trusted only when its recorded HEAD matches the current commit (verify-done already ran the exact CI checks — no redundant re-run); otherwise lint + typecheck + test + build; deletion-only and tag-only pushes exempt |
| `retro-nudge.sh` | session stop | after ≥3 gate blocks in a session, suggests `/retro` once so the friction gets encoded, not repeated |
| `context-nudge.sh` | session stop | once context usage crosses 50% of the window (read from the transcript's last usage entry), suggests `/handoff` or a fresh session once — long contexts slow every response and degrade quality. Window defaults to 200k; set `CONTEXT_WINDOW_TOKENS=1000000` for 1M sessions, `CONTEXT_NUDGE_PERCENT` to move the threshold |
| `symlink-check.sh` | session start | warns on symlink drift and on a missing `jq` (which now blocks git commands until it is installed) |
| `auto-sync-config.sh` | session start | fast-forwards the config repo from origin when clean and on main (throttled; repo located via the `CLAUDE.md` symlink, not a hardcoded path). Updates that touch executable config (`hooks/`, `scripts/`, `settings.json`) are held for manual review, never auto-merged |

Hook-authoring rule: command-matching gates need negative tests where the trigger text appears as *data* — quoted arguments, heredoc bodies, prose, and **filenames/paths** (this repo's own `pre-push-*.sh` names contain every trigger word) — not just as a command. When broadening a gate's match patterns, re-audit the extraction feeding them: a token class that was safe over exact matches can be unsafe over misparsed data. And before shipping any gate change, dry-run the gate against its own release — pipe the exact commit/push command you are about to run through the hook as a payload. The merge gate blocked its own release PR twice, and the force/verify gates blocked their own hardening commits twice, before this was encoded. Staleness tests backdate the artifact with `touch -t` and keep the default TTL — never set a TTL of 0, because BSD `find -mmin -0` is unreliable. And removing a gate requires, in the same commit, tests proving the invariant it guarded still holds elsewhere — the protection ledger must never depend on memory.

All hooks detect the package manager from the lockfile (bun/pnpm/yarn/npm) and have `SKIP_*` env bypasses for emergencies. The bypasses are **deliberately human-only**: hooks run in the harness process, so an inline `SKIP_*=1` prefix on the agent's command never reaches them — export the variable in the shell that launches the session, or run the command yourself with the `!` prefix. The agent cannot bypass its own gates. The commit gates match both `git commit` and cross-repo forms (`git -C <path> commit`, `cd <path> && git commit`) and gate on the branch of the repo the commit actually targets. Every gate has a regression suite in `tests/` (`bash tests/run-all.sh`).

## Licensing

[MIT](LICENSE) — reuse freely. Vendored/adapted third-party material is MIT-licensed and credited in [NOTICE.md](NOTICE.md). The refactoring-ui plugin is installed from its source repo at setup time rather than vendored, because its upstream LICENSE is all-rights-reserved and forbids redistribution. Machine- or employer-specific settings (work plugins, internal permissions) belong in `~/.claude/settings.local.json`, which is never committed.
