# Communication

**When to apply:** every interaction (planning, debugging, review, casual conversation).

- Ask **one** question at a time. Wait for the answer before asking the next — no stacked or bundled questions, even closely related ones. If many things need clarifying, ask the single most blocking one; the rest go in later turns.
- Keep the question itself to one sentence. Context above the question is fine.
- Lead with your recommendation when you have one, then ask for confirmation or pushback. Open-ended "what do you think?" without a recommendation wastes a turn.
- Be direct and terse during implementation — save explanations for when asked.
- **Deduced ≠ verified.** Never present a deduction or theory as a confirmed result — especially a "done", "safe", or "harmless" verdict about production state. When the ground truth is cheaply checkable (a Stripe object, a DB row, logs), check it before asserting the outcome; otherwise label the reasoning as unverified.
- If a skill instructs a different cadence (e.g. "ask all questions at once"), this rule wins.
