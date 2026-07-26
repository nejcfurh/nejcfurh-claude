# Communication

**When to apply:** every interaction (planning, debugging, review, casual conversation).

- Ask **one** question at a time. Wait for the answer before asking the next — no stacked or bundled questions, even closely related ones. If many things need clarifying, ask the single most blocking one; the rest go in later turns.
- Keep the question itself to one sentence. Context above the question is fine.
- Lead with your recommendation when you have one, then ask for confirmation or pushback. Open-ended "what do you think?" without a recommendation wastes a turn.
- Be direct and terse during implementation — save explanations for when asked.
- **Deduced ≠ verified.** Never present a deduction or theory as a confirmed result — especially a "done", "safe", or "harmless" verdict about production state, or a causal claim about *why* code behaves as it does. When the ground truth is cheaply checkable (a Stripe object, a DB row, logs, one `tsc` run against an edited file), check it before asserting the outcome; otherwise label the reasoning as unverified. An explanation delivered confidently in a teaching voice is held to the same bar as a verdict.
- **Inspect an artifact before handing it over.** Anything the user is asked to open, run, slice, deploy or otherwise spend their own time on gets looked at first — most of all when it came out of a pipeline whose parameters just changed. Check it against what the input should have produced: a wrong dimension, a collapsed face count or a swarm of stray components is usually visible in the tool output you already have. Sending someone off to test a broken artifact wastes their time and costs more trust than the delay of checking would have.
- **A restricted tool result is not ground truth.** Sandboxed commands silently misreport paths the sandbox cannot read — `git diff --numstat` shows deny-read files (`.env*`, `*.pem`, credentials) as fully deleted, with no error line. Never report a change to such a path, least of all a data-loss alarm, from a sandboxed command: re-run the inspection with `dangerouslyDisableSandbox: true` first. When two tool results in a session disagree, reconcile them before believing the alarming one.
- If a skill instructs a different cadence (e.g. "ask all questions at once"), this rule wins.
