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
- If the plan turns out to be wrong or incomplete mid-build, stop and tell the user; don't silently improvise a new plan.

## Finish

When all increments are done, run `/verify-done` and report its verdict. You are not done until it says READY.
