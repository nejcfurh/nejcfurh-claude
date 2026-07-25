---
paths:
  - "**/*.{ts,tsx,js,jsx,mjs,cjs}"
  - "**/*.sh"
---

# Comment Standards

**When to apply:** writing or editing any code file.

The baseline is the surrounding code — match its comment density and idiom. What follows are the standing preferences that override that baseline where the two disagree.

## Write a comment for a non-obvious WHY

- A hidden constraint ("must run before X because Y")
- A subtle invariant ("must be even — modulo math relies on it")
- A workaround for a known bug ("v4.2.1 of foo throws on empty input")
- Behavior that would surprise a reader without the surrounding context

Prefer one line. Multi-line only when the WHY genuinely needs it.

## Leave these out, even where neighbouring code has them

- **WHAT-restating comments** — anything paraphrasing the next line (`// increment counter` above `counter++`).
- **Ticket / PR / issue references** in comments (`JIRA-123`, `#456`, `Fixes ...`) — these belong in PR descriptions and `git blame`, where they stay accurate.
- **Comments addressed to the reviewer** ("this fixes the bug by...", "changed per feedback") — that's PR-description content, noise once merged.
- **TODO/FIXME markers** without an open tracker entry — open the ticket, fix it now, or accept it isn't getting fixed.
