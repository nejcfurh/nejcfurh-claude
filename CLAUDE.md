# Global Rules

These apply to every project. Project-level CLAUDE.md files override where they conflict. Detailed conventions live in `rules/` (loaded automatically each session).

## Priority order

When goals conflict: **quality > consistency > efficiency > speed**. Shipped bugs cost more than slow shipping.

## Workflow

1. **Understand first**: before choosing an approach, check how similar problems are already solved in the codebase — grep for existing patterns, read neighboring files. Follow established conventions over personal preference. When that search turns up an existing design-system component, asset or helper for the thing being built, it **is** the answer — implement with it. Do not hand it back as one option among alternatives you invented: only one entry on that menu matches the rest of the app, and offering the others invites an inconsistency the user then has to catch in review.
2. **Align when it matters**: for non-trivial or ambiguous work, plan before implementing. For large features or architectural decisions, use `/grill` to stress-test the plan question by question. For quick fixes, a short stated plan is enough.
3. **Implement with gates**: run typecheck and tests yourself after each increment — that is the implementer's job, not a hook's. Hooks enforce them at the publish boundary (`gh pr create`, `git push`); only formatting runs on edit. Follow `/build` discipline for multi-step plans: small increments, commit atomically, no drive-by refactors.
4. **Verify before done**: run `/verify-done` before pushing — it discovers and runs exactly what CI runs. UI changes additionally get browser/simulator-level verification via the `verify-frontend-change` skill. Never push without all checks passing.

A change is a **UI change if it alters what renders**, whatever file it lives in. Layout coordinates, ordering, selection, spacing and thresholds are UI code even when they sit in a pure `.ts` function behind unit tests — those tests confirm the maths matches your intent, never that the intent looks right. Once the app is already running on a simulator or browser this costs one screenshot; skipping it is how a green suite ships a visibly broken screen.

Trivial bypass: typos, single-line fixes, version bumps, config tweaks — skip straight to implementation.

Model per phase: steps 1–2 run on Fable 5, steps 3–4 on Opus 5 (1M context). Route subagents and workflow nodes accordingly; flag the session-level switch at the plan/implement boundary, since only `/model` can make it. See `rules/orchestration.md`.

## Loops

- For tasks with a verifiable finish line, prefer `/goal` with deterministic stop criteria and a turn cap — e.g. `/goal all /verify-done checks pass, stop after 5 tries`. For recurring external checks (PR reviews arriving, CI runs), use `/loop <interval> <prompt>` instead of polling manually or building custom watchers.
- Every loop declares its budgets up front: max attempts (default 5), zero new dependencies, zero scope expansion.
- Loops only get machine-checkable work — lint fixes, dependency bumps, CI triage, flaky-test reproduction. Never auth, payments, architecture, or anything where "done" is a judgment call.
- Setting one up, or deciding whether to: `/loop-discipline` carries the pre-flight checklist, the escalation triggers, and the state-file requirement.

## Behavioral rules

- **Scope**: only implement what was asked — no drive-by refactors, extra features, or unsolicited improvements.
- **Repo boundaries**: crossing into a different repository than the one in play is a decision point requiring its own sign-off — a "go ahead" in repo A does not authorize writing in repo B. Analyze/read across repos freely, but before creating branches, worktrees, or commits in a second repo, present the concrete diff/plan and hand it off for the user to run there.
- **Minimal fix**: for bugs, find the root cause and state the smallest possible change first. Expand scope only if the minimal fix is provably insufficient. Never introduce new abstractions or files as part of a bug fix unless asked.
- **Decisions**: ask before making architectural choices — never silently pick a pattern, library, or approach.
- **Testing**: write tests when implementing a feature or fixing a bug.
- **Cost**: warn before any change that increases costs (new cloud resources, paid services, upgraded tiers).
- **Questions**: one clarifying question per turn, lead with your recommendation. See `rules/communication.md`.

## Security

- Never read or process files containing secrets, credentials, API keys, or private keys — any `.env` variant, `*.pem`, `*.key`, `credentials.json`, `~/.ssh`, `~/.aws`, etc. Treat this as the rule; `permissions.deny` enforces most of it but **enumerates** `.env` filenames rather than wildcarding them (a wildcard would negate the deliberate `.env.example` allows), so an unusual name may not be blocked by tooling. Do not attempt workarounds.
- If config values are needed for debugging, ask for the non-sensitive parts only.
- Read the source of any third-party skill, plugin, or agent before installing — skill descriptions and instructions are prompt-injection vectors.
- Widening a permission pattern: enumerate the **benign everyday commands** the new pattern now catches, and say so before proposing it. An `ask` on a routine command (`rm -f <file>`) is friction paid on every use with no safety return — the dangerous variants belong in `deny` and the pattern in `ask` should stay narrow enough that a prompt means something. Tightening `deny` is the opposite trade and needs the same check, since `deny` cannot be relaxed per invocation.

## Learning from mistakes

- When corrected, update the relevant rule file or CLAUDE.md so the mistake is not repeated. Check whether an existing rule already covers it — update rather than duplicate.
- After a session that went sideways or required corrections, run `/retro` — it grades the trajectory and encodes the fixes (hook > rule > skill > memory) instead of leaving them as good intentions.
- **A memory is only as findable as its index line.** The index is what loads into context; the file itself goes unread until that one line makes it look relevant. So the line must name every distinct failure class the file covers, not just the headline one — when a file grows a second lesson, update its index entry too, or that lesson is invisible at recall time and gets re-derived at full cost. Symptom: spending several rounds rediscovering something, then finding it already written down.

## Environment

- macOS, zsh. Stack: TypeScript, React, React Native, Next.js, NestJS, PostgreSQL.
- Package manager varies per project — detect from the lockfile, never assume npm.
- Figma MCP is available for design work; Context7 MCP for library docs (see `rules/context7.md`).
- Custom subagents live in `agents/` — the harness lists each with its description, so don't restate them here. Spawn via the Agent tool for substantial work in those domains; skip for trivial changes.
