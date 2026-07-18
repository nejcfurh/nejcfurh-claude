---
name: debug
description: Evidence-first incident investigation in three strict phases. Invoke when given an error message, stack trace, failing logs, an error-tracker or issue link, or a request to "investigate X".
---

Investigate: $ARGUMENTS

Work through three phases IN ORDER. Do not skip ahead.

## Phase 1 — EVIDENCE (facts only; proposing fixes here is forbidden)

Collect:

- The exact error message and full stack trace, verbatim.
- Reproduction steps — actually reproduce it if you can.
- Recent changes: `git log --oneline -20`, and diffs of anything touching the failing area.
- Relevant logs around the failure.
- If the user provided an error-tracker or issue link, fetch and read it FIRST — it usually has the stack, frequency, affected versions, and breadcrumbs.

Output a short evidence summary. No theories yet.

## Phase 2 — HYPOTHESES

Enumerate hypotheses, ranked most to least likely. For each:

- **Evidence for** — which facts support it.
- **Evidence against** — which facts contradict it.
- **Cheapest test** — the fastest experiment that would confirm or eliminate it (a log line, a targeted unit test, a REPL check, reverting one commit).

Work down the list running the cheapest tests, eliminating hypotheses until one survives.

## Phase 3 — FIX

1. Verify the root cause with a targeted experiment or a failing test BEFORE changing any code.
2. Apply the minimal fix — the smallest change that removes the root cause.
3. Add a regression test that fails without the fix and passes with it.
4. Run `/verify-done`.

## Anti-patterns — never do these

- Adding retries or try/catch as a "fix" for an unexplained error.
- Fixing the symptom instead of the cause.
- Expanding scope ("while I'm in here...").
- Shotgun debugging — changing several things at once so you can't tell what worked.
- Claiming a root cause without evidence that proves it.
