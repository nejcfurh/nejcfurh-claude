---
name: retro
description: Grade the session's trajectory, not just its outcome, and encode what went wrong into the config so it can't recur. Invoke after a correction, a session that went sideways, or when the user says "retro", "what went wrong", or "make sure this doesn't happen again".
---

Run a retrospective on: $ARGUMENTS (default: this session's work)

The outcome may even be fine — the question is whether the *path* was right, and what the config should learn from it.

## 1. Reconstruct the trajectory

List what actually happened, in order: the task as stated, the assumptions made, files read and touched, commands run, gates that fired (or should have), corrections the user had to make. Facts only — no defense of decisions.

## 2. Grade the trajectory

For each misstep, classify it:

- **Wrong assumption** — acted on stale or guessed context instead of checking (didn't read the file, trusted conversation memory over `git status`).
- **Scope drift** — touched things the task didn't ask for.
- **Missed gate** — a hook/check existed but was bypassed, or the failure class has no gate at all.
- **Rule gap** — no rule covers this; the mistake was reasonable given the config.
- **Rule ignored** — a rule covers this and wasn't followed; the rule may be buried, ambiguous, or contradicted elsewhere.

## 3. Encode the fix (the point of the exercise)

For each finding, propose the *cheapest durable fix*, preferring mechanical over attentional:

1. **Hook** — if it's pattern-checkable at tool-call time, it becomes a gate, not advice.
2. **Rule edit** — if it's a judgment call, add or sharpen a line in `rules/` or CLAUDE.md; update the existing rule rather than adding a duplicate.
3. **Skill edit** — if a workflow step was skipped or misordered, fix the skill that owns that workflow.
4. **Memory** — if it's a fact about this user/project rather than a rule, save it to memory.
5. **No fix** — genuinely one-off; say so and don't add config noise. A rule nobody needed twice is bloat.

## 4. Apply

Present the findings and proposed fixes as a short table (misstep → class → fix → where). On approval, make the edits in the config repo and commit. One retro finding that becomes a hook is worth ten that become paragraphs.

### Write it so it cannot leak

The config repo is shared, outlives any single engagement, and may be public. Everything a retro puts there — rule text, commit message, PR title and body, branch name — must read as generic craft guidance and carry nothing identifying where the lesson came from.

Never write: client, company or product names; ticket identifiers or their prefixes; internal repo, service, environment, table or flag names; links to internal tools; verbatim internal conventions or guidelines; file paths that exist only in that codebase.

Generalize instead — "a client project", "a ticket", "an internal ticket-prefix convention", "a project-specific env file". A finding that needs the original repo named to make sense is not yet a rule.

**Never encode one project's convention into a global rule, gate or hook.** If it only makes sense for one codebase it belongs in that project's own config. Split every finding: the generalized lesson goes to the config repo, the specifics and evidence go to memory, which is per-project and private.

Before committing, grep the staged diff **and** the commit message and PR body for the client's names and ticket pattern. The rule text is usually already clean — the commit message and PR body are where it leaks.
