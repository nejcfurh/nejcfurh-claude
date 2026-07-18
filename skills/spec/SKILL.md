---
name: spec
description: Turn an ambiguous feature request into an approved, implementable spec before any code. Invoke when the user says "write a spec", "define requirements", or brings a new-feature request that is too vague to build from.
---

Spec out: $ARGUMENTS

## 1. Discovery interview

Ask ONE question per turn — never a questionnaire. Cover, roughly in order:

- Who is this for? (user/persona, and where they hit it)
- What exactly should happen? (concrete behavior, walk through an example)
- Why? What problem does it solve — what happens today without it?
- Constraints: deadlines, tech, compatibility, design, compliance.
- What is explicitly OUT of scope?

Skip questions the user has already answered. Stop when you can state the feature back precisely; don't interrogate past the point of usefulness.

## 2. Draft the spec

Write a document with these sections:

- **Problem** — the situation today and why it needs to change.
- **User stories** — "As a <who>, I want <what>, so that <why>."
- **Acceptance criteria** — each one independently testable; prefer criteria checkable by running a command or a test.
- **Non-functional requirements** — performance, accessibility, security, i18n, as relevant.
- **Constraints** — technical and product constraints from discovery.
- **Out of scope** — explicit exclusions, so nobody builds them "helpfully".
- **Open questions** — anything unresolved, each assigned to someone or something.

## Quality bar: RE-RUNNABLE

A fresh agent with zero conversation history must be able to implement from this document alone. That means:

- No "as discussed" or "see above" — restate everything the implementer needs.
- Concrete file paths, route names, component names, table names — not "the relevant module".
- Acceptance criteria phrased so they can be verified by running commands.

## 3. Save and get approval

Save to `docs/specs/YYYY-MM-DD-<topic>.md` (today's date; ask if the user prefers another location). Present it for review and iterate until the user EXPLICITLY approves. Do not start implementation before approval — once approved, hand off to the `build` skill.
