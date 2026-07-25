---
name: loop-discipline
description: Pre-flight checklist, escalation triggers, and state-file requirements for a `/loop` or `/goal` run. Invoke before building a recurring or scheduled loop, when deciding whether a task belongs in a loop at all, or when a loop keeps failing and needs to escalate instead of retrying harder.
---

# Loop Discipline

The budget rules and the machine-checkable-work-only constraint live in CLAUDE.md and are always in context. This skill covers the rest: whether a loop is the right shape at all, when to abandon one, and how to make it resumable.

## Before building one

A scheduled loop or routine needs all three. Miss one and it stays a manual prompt:

1. **The task recurs** — a one-off does not become a loop because it might repeat someday.
2. **An automated check can reject bad output** — a test, typecheck, build, or lint run. Without a machine gate, a loop just accumulates unreviewed work.
3. **There is a hard stop** — a turn cap or a budget. A loop with no stop condition is a runaway.

## Escalate instead of retrying

Stop early and hand back to the user when any of these hits:

- The same root cause survives two distinct fixes.
- Two consecutive iterations fail identically.
- An iteration needs a product decision or an irreversible action.

Retrying harder past these points burns budget without changing the outcome. Escalation is the designed exit, not a failure.

## Long-running work

Prefer restarting from a self-contained spec or handoff over grinding through a degraded session — re-feeding the spec beats context rot. `/spec` writes re-runnable specs; `/handoff` compacts a session into one.

## Resumability

Scheduled loops keep a state file (e.g. `STATE.md`) recording what is done, in progress, and escalated, so a run resumes instead of restarting from zero.

## Gates still apply

Loops inherit the same hooks and gates as manual work — verification runs inside every iteration. A loop cannot skip `/verify-done` or push past a blocked gate.
