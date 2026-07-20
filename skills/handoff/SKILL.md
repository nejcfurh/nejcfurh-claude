---
name: handoff
description: Compact the current conversation into a handoff document for another agent to pick up.
argument-hint: "What will the next session be used for?"
---

> Source: [mattpocock/skills — productivity/handoff](https://github.com/mattpocock/skills/tree/main/skills/productivity/handoff)

Write a handoff document summarising the current conversation so a fresh agent can continue the work. Save it to a path produced by `mktemp -t handoff-XXXXXX.md` (read the file before you write to it).

Use exactly this structure — a fixed skeleton means the next session never hunts for the state it needs. Omit a section only when it is genuinely empty:

```markdown
# Handoff

## Goal
<what the work is trying to achieve — one paragraph>

## Current state
- Branch: <name>
- HEAD: <short SHA + subject>
- Dirty files: <paths, or "clean">
- Verification: <READY / READY TO COMMIT / NOT READY / not run>

## Completed
<what is done AND verified>

## Remaining
<what is left, in intended order>

## Decisions
<choices made and why — link ADRs/specs instead of restating them>

## Failed approaches
<what was tried and abandoned, and why, so it isn't repeated>

## Next command
<the exact first command or skill invocation the next session should run>
```

Suggest the skills to be used, if any, by the next session.

Do not duplicate content already captured in other artifacts (PRDs, plans, ADRs, issues, commits, diffs). Reference them by path or URL instead.

If the user passed arguments, treat them as a description of what the next session will focus on and tailor the doc accordingly.
