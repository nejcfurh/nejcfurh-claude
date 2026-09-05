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

Everything is symlinked, so edits in `~/.claude` and in the repo are the same files — commit when it stabilizes. Existing files are backed up to `<path>.bak.<timestamp>`.

**Where machine-local overrides go.** Claude Code resolves the `settings.local.json` variant at *project* scope only, so `~/.claude/settings.local.json` is **not loaded** — env vars, `model`, or extra permission rules put there are a silent no-op. Machine-local `env` and permissions belong in `~/.claude/settings.json` itself (it is the symlinked repo file, so keep them out of commits, or accept them as shared config). Project-scoped overrides in a repo's own `.claude/settings.local.json` work as documented. The active `model` is per-machine runtime state — a git filter strips it from `settings.json` so it is never committed; set yours with `/model`.

Gate prerequisites: **`jq` is required** — every git gate parses its hook payload with it. Without jq, `setup.sh` aborts the install (pass `--allow-insecure-no-jq` to override) and the git-gate dispatcher fails **closed**, blocking every git command (`SKIP_GIT_GATE_NO_JQ=1` to bypass) rather than letting commands run ungated. `gitleaks` is recommended — without it the secret gate falls back to built-in patterns only.

## What's inside

| Path | Contents |
| --- | --- |
| `CLAUDE.md` | Core global rules: priority order, workflow, loops, behavioral rules, security, environment |
| `rules/` | Auto-loaded conventions: communication, comments, git, typescript, tests, engineering principles, context7, orchestration |
| `skills/` | Workflow: `grill`, `build`, `verify-done`, `ship`, `debug`, `test`, `prune`, `spec`, `review-pr`, `address-pr-comment`, `commit`, `pr`, `rebase`, `handoff`, `verify-frontend-change`, `retro`, `loop-discipline` · Docs: `context7-mcp`, `find-docs`, `review-code` · Design (Emil Kowalski): `emil-design-eng`, `apple-design`, `animation-vocabulary`, `find-animation-opportunities`, `improve-animations`, `review-animations` |
| `agents/` | Opt-in subagent personas — see [Personas](#personas) |
| `hooks/` | Full quality gates (see below) |
| `scripts/` | `setup.sh`, `statusline.sh`, `notify.sh`, `chime.sh` (Stop/Notification sound), `detect-parent-branch.sh` (stacked-PR base detection), `lint-config.sh` (CI lint of hook wiring, frontmatter, dead references), `record-verify-pass.sh` (mints the `/verify-done` READY marker, clean tracked tree only), `verify-plan-fingerprint.sh` (hashes the check-plan inputs that key `/verify-done`'s plan cache), `strip-ephemeral-state.sh` (the git clean filter that keeps per-machine runtime state — `.model`, `.feedbackSurveyState` — out of committed `settings.json`; wired by `setup.sh`) |
| `tests/` | Regression suites for every hook and script with gate logic — `bash tests/run-all.sh` (suites run concurrently, output printed in stable order) |
| `settings.json` | 91-rule permission deny-list (Read/Edit tools + Bash command forms), OS-level sandbox `denyRead` for home credential stores, hook wiring, plugins, statusline |

**Secret-read boundary (scoped honestly).** The `Read`/`Edit` deny rules block those *tools* from touching `.env`, private keys, and cloud credentials — they do **not** constrain Bash, so `cat .env` still works. That is deliberate: local app runs (`npm run dev`) and "does this var exist" checks need project `.env` readable. Bash-level containment comes from the sandbox, not the deny-list: `sandbox.filesystem.denyRead` makes a handful of home credential stores (`~/.gnupg`, `~/.git-credentials`, `~/.netrc`, `~/.pypirc`, `~/.vault-token`) unreadable to every Bash subprocess at the OS level, and Bash network egress is restricted to an allowlist by the Claude Code sandbox **runtime** — not by anything in this repo's `settings.json` — which raises the cost of shipping a secret that *is* read to an arbitrary host. Treat that egress limit as a runtime-provided speed bump, not a guarantee this config makes: it depends on the sandbox behavior of your Claude Code version, so confirm it there rather than relying on it. `~/.ssh` and `~/.aws`/`gcloud` are intentionally left readable so `git push` and local cloud SDKs keep working — widen `denyRead` per-project in a project's own `.claude/settings.local.json` if a machine warrants it.

**Two deliberate rough edges in `permissions`.** The destructive-SQL denies (`Bash(*DROP TABLE*)` and friends) are unanchored substrings with no quote awareness, so they also block a command that merely *mentions* the phrase — `grep -rn "DROP TABLE" notes.md` is refused. That is kept on purpose: narrowing them to command-shaped patterns would need one entry per SQL client and would trade a rare, obvious annoyance for a real hole, and `deny` cannot be relaxed per-invocation. The principled fix is a hook that blanks quoted spans before matching, the way `pre-merge-gate.sh` does. Separately, the `.env` denies **enumerate** filenames rather than wildcarding: `Read(**/.env.*)` would be broader but `deny` beats `allow`, so it would negate the deliberate `.env.example` / `.env.sample` allows. An unusual `.env` variant may therefore not be blocked by tooling — the rule in `CLAUDE.md` covers it, the glob list does not.

## Workflow (lightweight by default)

1. **Understand** — check how the codebase already solves similar problems.
2. **Align** — plan for non-trivial work; `/grill <topic>` for large features and architectural decisions (interviews you one question at a time, writes CONTEXT.md terms and ADRs as decisions crystallize).
3. **Implement** — `/build` discipline: small increments, continuous typecheck/tests, atomic commits.
4. **Verify** — `/verify-done` before every push (hooks enforce it at push time anyway). Discovering what CI runs is the expensive step, so the skill caches its discovered command plan in `.git/verify-done-plan`, keyed by `scripts/verify-plan-fingerprint.sh` (a hash of CI workflows, package manifests, and lockfiles) — rediscovery happens only when one of those inputs changes.

Trivial changes (typos, one-liners, version bumps) skip everything.

## Loops

Verification skills + hooks are the foundation; Claude Code's loop primitives build on them:

| Loop | Reach for | Example |
| --- | --- | --- |
| Turn-based | Verification skills | `/verify-done`, `verify-frontend-change` run inside every turn |
| Goal-based | `/goal` + deterministic criteria | `/goal all /verify-done checks pass, stop after 5 tries` |
| Time-based | `/loop` / `/schedule` | `/loop 5m check my PR, address review comments, fix failing CI` |

No custom CI-watcher machinery needed — `/loop` covers PR babysitting natively, and the push gates fire inside every loop iteration, so a loop won't *accidentally* hand back unverified work. These are cooperative guardrails, not an unbypassable boundary: the READY marker is a file the session itself can write, so they reliably catch the common accidental miss — not an agent set on routing around them. The marker is bound to the verified commit (see the push-gate rows below) and is only ever minted for a clean tracked tree (`scripts/record-verify-pass.sh` refuses otherwise — a push publishes commits, not the working tree, so a dirty-tree pass is READY TO COMMIT, not push-ready). That closes the stale-marker and dirty-tree cases, but not the forge-it case.

The PR-babysitting loop is a composition, not new machinery — `/loop` for the cadence, the `address-pr-comment` skill for the work, explicit budgets for the stop:

```
/loop 10m if PR checks are green and no unresolved review comments remain, stop the loop;
otherwise run /address-pr-comment and fix failing CI. Never merge. Stop after 6 cycles,
or if the same check fails twice for the same root cause — escalate instead.
```

Grouping comments by root cause, batching the fixes, and re-verifying before push all happen inside `address-pr-comment` and the push gates — the loop only supplies cadence and budgets.

## Workflows (fan-out orchestration)

The loops above are *temporal* — one head, repeated. A **Workflow** is *spatial* — one wide fan-out within a turn, a fleet of subagents coordinated by a plain-JS script whose control flow costs zero model tokens. `rules/orchestration.md` governs when to reach for one (independent breadth, gated verification, unknown-size discovery) versus a linear pass, and the opt-in it requires — a Workflow never fans out unprompted, since one run can spawn dozens of agents. Repo-scoped example in `.claude/workflows/config-consistency-audit.js`: fan out one agent per subsystem (rules, docs, hooks, permissions, skills/agents) → verify each finding against the files → synthesize a ranked report. Launch it by path (project-local scripts aren't resolved by name in this harness — only built-ins are), watch it live with `/workflows`.

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
| `pre-git-sandbox-config-gate.sh` | any git command | blocks git commands that write `.git/config` while the command sandbox is on. These fail **half-way** — `git checkout -b` creates the ref but leaves HEAD put and the index holding the start point's tree; `git push -u` publishes the branch and fails only the tracking write — so the gate stops them and names the retry instead of leaving a half-applied state to reconstruct |
| `pre-git-sandbox-tree-gate.sh` | any git command | sibling of the above for the working tree: a sandboxed pull hits denied paths, reports `unable to unlink old '<path>'` per file and aborts after already rewriting an unknown number of the rest. Measured once at several hundred files rewritten with HEAD unmoved — indistinguishable from real uncommitted work without diffing against the remote |
| `pre-git-branch-switch-gate.sh` | git checkout/switch | blocks moving a checkout onto an existing branch while tracked files are modified. git allows this silently: when the changes don't conflict it carries them across and reports success, so someone else's in-progress work ends up on a branch it was never written for. A `git status` from earlier in the session is a stale read — only a check at call time sees the truth |
| `gh-gate-dispatch.sh` | any gh command | the single PreToolUse entry for the gh gates, mirroring the git dispatcher: parses the payload once and routes by subcommand, so `pre-git-state-refresh` runs LAST and only when nothing blocked. Previously three independent settings.json entries with undefined ordering, so a rejected `gh pr merge` still paid for an API round-trip whose JSON leaked into the block output |
| `pre-gh-stack-commit-gate.sh` | gh stack | refuses to let `gh stack init\|add -A -m` create the commit. That command line contains no `commit`, so the git dispatcher never routes it and the branch, co-author, conventional-message and secret gates all sit out a real commit — as does any repo-side `commit-msg` hook. `gh stack` owns branch topology; `git commit` owns content |
| `pre-push-marker-chain-gate.sh` | git push | rejects a command that records the `/verify-done` marker and pushes in one invocation. PreToolUse evaluates the whole command before any of it runs, so the marker does not exist yet when the verify gate looks — the chained form always fails, and with a misleading "no fresh pass" message rather than its real cause |
| `pre-bash-pipe-status-gate.sh` | any Bash command | warns when a command whose exit status is load-bearing (build, test, typecheck, install, migration, db client) is piped into a pager-ish filter, so `$?` belongs to the filter and reports success however the left side failed. Inspection pipelines (`git log \| head`) are deliberately left alone — a gate that fires on those is noise. Non-blocking |
| `pre-bash-build-dev-server-gate.sh` | any Bash command | warns when a production build is about to run while a dev server is listening — `next build`/`next dev` both own `.next`, `vite build`/`vite dev` share `dist`. The build overwrites the manifests the running server serves from; the server keeps answering and every route 500s, which looks nothing like its cause. Checks the **port** with `lsof`, not a process name. Non-blocking |
| `pre-write-comment-gate.sh` | file write/edit | blocks a new prose comment when the nearest up-tree `CLAUDE.md` prohibits comments. Encodes no project: the prohibition is read from that file. Narrow by design — JS/TS-family sources only, only comments the write actually introduces, and tooling directives (`@ts-`, `eslint-disable`, `/// <reference>`) are exempt |
| `auto-format.sh` | file edit | Biome/Prettier format (local `node_modules/.bin` when present, npx fallback) |
| `invalidate-verify-marker.sh` | file edit | deletes the repo's `/verify-done` marker — checks that passed before an edit say nothing about the tree after it |
| `pre-commit-branch-gate.sh` | git commit | blocks commits on main/master |
| `pre-commit-coauthor-gate.sh` | git commit | blocks Co-Authored-By / AI attribution |
| `pre-commit-conventional-gate.sh` | git commit | enforces conventional commits |
| `pre-commit-secret-gate.sh` | git commit | secret scan of everything the commit could publish (staged, unstaged tracked, untracked) — gitleaks when installed plus built-in high-confidence patterns |
| `pre-git-state-refresh.sh` | git/gh writes | injects ground-truth PR state (cached ~60s per repo+branch — advisory context, no gate reads it) |
| `pre-merge-gate.sh` | gh | blocks `gh pr merge` (and the `gh api …/merge` fallback) — the user merges PRs manually |
| `pre-pr-test-gate.sh` | gh pr create | smoke-test fallback in the checkout the command targets: a fresh `/verify-done` READY marker whose recorded HEAD matches the current commit is trusted (tests already certified — no re-run); without a matching marker, tests must pass — and deliberately mint no marker, since a tests-only pass must not certify the full suite |
| `pre-push-branch-gate.sh` | git push | blocks pushes targeting the repo's default branch, whatever its name — bare `git push`, `HEAD`, refspecs, `--all`, `--delete` |
| `pre-push-author-gate.sh` | git push | blocks pushes whose outgoing commits carry a foreign author — fixture commits and tooling artifacts never ride along unnoticed |
| `pre-push-verify-gate.sh` | git push | requires a fresh `/verify-done` READY marker (`.git/verify-done-ok`) whose recorded HEAD matches the pushed commit — a later commit, amend, or rebase invalidates it (as does any edit); TTL backstop expires it; deletion-only (`--delete`, `:branch`) and tag-only pushes exempt |
| `pre-push-gate.sh` | git push | fallback suite in the checkout the push targets: a fresh `/verify-done` READY marker is trusted only when its recorded HEAD matches the current commit (verify-done already ran the exact CI checks — no redundant re-run); otherwise lint + typecheck + test + build; deletion-only and tag-only pushes exempt |
| `retro-nudge.sh` | session stop | after ≥3 gate blocks in a session, suggests `/retro` once so the friction gets encoded, not repeated (blocks are tallied by `record-gate-block.sh`, the shared helper every blocking gate calls) |
| `context-nudge.sh` | session stop | as context usage crosses 50%, 75% and 90% of the window (read from the transcript's last usage entry), suggests `/handoff` or a fresh session — long contexts slow every response and degrade quality. Each tier fires at most once and the advice escalates, so the second and third say something the first did not. A single nudge was not enough: sessions here run past 500k routinely and some come within 5% of a 1M window, leaving the whole expensive half unwarned. Window defaults to 200k; set `CONTEXT_WINDOW_TOKENS=1000000` for 1M sessions, `CONTEXT_NUDGE_PERCENT` to a comma-separated tier list (a single value still means one tier) |
| `symlink-check.sh` | session start | warns on symlink drift and on a missing `jq` (which now blocks git commands until it is installed) |
| `auto-sync-config.sh` | session start | fast-forwards the config repo from origin when clean and on main (throttled; repo located via the `CLAUDE.md` symlink, not a hardcoded path). Updates that touch executable config (`hooks/`, `scripts/`, `settings.json`) are held for manual review, never auto-merged |

Hook-authoring rule: command-matching gates need negative tests where the trigger text appears as *data* — quoted arguments, heredoc bodies, prose, and **filenames/paths** (this repo's own `pre-push-*.sh` names contain every trigger word) — not just as a command. Detection belongs in the shared tokenizer, never in a per-gate regex or substring: five hand-rolled copies drifted apart until `git --no-pager commit` walked past all four commit gates at once, secret scan included. A new gate calls `git_cmd_scan`; it does not write its own matcher.

**Replacing a matcher requires proving it is a SUPERSET.** A rewrite is only safe if every command form the old matcher caught is still caught — test the *catching* direction, not just the bypasses you set out to close. Enumerate what the old one matched and assert the new one still does, or run both over a corpus and require no form to move from caught to uncaught. This is not hypothetical: replacing the literal `"git commit"` substring with a tokenizer closed four exotic bypasses and silently opened three everyday ones (`(git commit …)`, `$(git commit …)`, `{ git commit; }`) because grouping characters were not separators — and that shipped, because the new tests only covered the direction being fixed. `tests/git-cmd-lib.test.sh` is the corpus; add to it before changing detection. When broadening a gate's match patterns, re-audit the extraction feeding them: a token class that was safe over exact matches can be unsafe over misparsed data. And before shipping any gate change, dry-run the gate against its own release — pipe the exact commit/push command you are about to run through the hook as a payload. The merge gate blocked its own release PR twice, and the force/verify gates blocked their own hardening commits twice, before this was encoded. Staleness tests backdate the artifact with `touch -t` and keep the default TTL — never set a TTL of 0, because BSD `find -mmin -0` is unreliable. And removing a gate requires, in the same commit, tests proving the invariant it guarded still holds elsewhere — the protection ledger must never depend on memory.

The two hooks that run project scripts — `pre-pr-test-gate.sh` and `pre-push-gate.sh` — detect the package manager from the lockfile (bun/pnpm/yarn/npm). Every **blocking** gate has a `SKIP_*` env bypass for emergencies; the advisory hooks (`auto-format.sh`, `auto-sync-config.sh`, `context-nudge.sh`, `invalidate-verify-marker.sh`, `pre-git-state-refresh.sh`, `record-gate-block.sh`, `retro-nudge.sh`, `symlink-check.sh`) have none — they never block, so the way to stop one is to unwire it in `settings.json`. The bypasses are **deliberately human-only**: hooks run in the harness process, so an inline `SKIP_*=1` prefix on the agent's command never reaches them — export the variable in the shell that launches the session, or run the command yourself with the `!` prefix. The agent cannot bypass its own gates. Every commit and push gate detects its subcommand through one shared quote-aware tokenizer (`hooks/git-cmd-lib.sh`), never a substring of the raw command. It resolves git-level options (`git --no-pager commit`, `git -c <cfg> push`, `git --git-dir=… commit`), cross-repo forms (`git -C <path> commit`, `cd <path> && git commit`), and **every** invocation on a command line — so a second `git push` after a `&&` is judged too — while treating the same words inside a quoted argument as data. Gates then act on the branch of the repo each invocation actually targets. Every gate has a regression suite in `tests/` (`bash tests/run-all.sh`).

## Licensing

[MIT](LICENSE) — reuse freely. Vendored/adapted third-party material is MIT-licensed and credited in [NOTICE.md](NOTICE.md). The refactoring-ui plugin is installed from its source repo at setup time rather than vendored, because its upstream LICENSE is all-rights-reserved and forbids redistribution. Machine- or employer-specific settings (work plugins, internal permissions) belong in `~/.claude/settings.json` — not `settings.local.json`, which Claude Code only reads at project scope — and should be kept out of commits.
