---
name: build
description: Implement an approved plan in small, verified increments. Invoke when the user says "build", "implement", or asks to start implementation of an agreed plan.
---

Implement: $ARGUMENTS

## Precondition: an agreed plan

Confirm a plan exists that both you and the user have aligned on — from this conversation, a plan file, or a spec. If there is no agreed plan, STOP. Do not start coding. Say what's missing and align on a plan first (offer the `spec` skill for ambiguous requirements).

## Work in increments

Break the plan into increments. Each increment is the smallest change that moves the plan forward and leaves the codebase working — a single function, one endpoint, one component, one migration.

For every increment:

1. Make the change.
2. Keep the build green as you go: run the typecheck and the tests relevant to what you touched. Detect the package manager from the lockfile (npm/yarn/pnpm/bun) — never assume npm.
3. Fix anything red before moving on. Never stack a new increment on a broken one.
4. Commit: one atomic conventional commit per completed increment (`feat(scope): ...`, `fix(scope): ...`, `refactor(scope): ...`). The commit should contain exactly that increment — nothing else.

## Scope discipline

- No drive-by refactors. If you spot unrelated ugliness, note it for the user; don't fix it now.
- No additions beyond the plan — no extra options, abstractions, or "while I'm here" features.

## Plan drift

Reality diverging from the plan mid-build is normal. Handle it by kind, not by stopping for everything:

**Proceed without asking** — routine, reversible deviations. Record each one in the final summary instead of interrupting:

- implementation details the plan never pinned down: internal naming, file layout, private helper structure
- an equivalent API of an already-chosen library when the planned one doesn't exist or is deprecated
- extra tests needed to prove planned behavior
- small compatibility fixes the change exposes in directly adjacent code (a type error, a broken import)

**Stop and tell the user** — these are the user's decisions, never improvised:

- external API or contract changes; schema or migration-strategy changes
- new dependencies; destructive or irreversible operations
- scope expansion, product-behavior changes, or security/privacy trade-offs
- the plan's approach is wrong at its core, not just in a detail

Every deviation either fits the proceed list or stops the build — there is no silent third option.

## Finish

When all increments are done, run `/verify-done` and report its verdict. You are not done until it says READY.
