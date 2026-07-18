# Comment Standards

**When to apply:** writing or editing any code file.

## Default

If the code is self-explanatory, write no comment. If it carries a hidden constraint, subtle invariant, workaround, or context a future reader can't derive from the surrounding code, write the shortest comment that captures it.

## Allowed: a non-obvious WHY

- A hidden constraint ("must run before X because Y")
- A subtle invariant ("must be even — modulo math relies on it")
- A workaround for a known bug ("v4.2.1 of foo throws on empty input")
- Behavior that would surprise a reader without the surrounding context

Prefer one line. Multi-line only when the WHY genuinely needs it.

## Forbidden

- **WHAT-restating comments** — anything paraphrasing the next line (`// increment counter` above `counter++`).
- **Ticket / PR / issue references** in comments (`JIRA-123`, `#456`, `Fixes ...`) — these belong in PR descriptions and `git blame`, where they stay accurate.
- **Comments addressed to the reviewer** ("this fixes the bug by...", "changed per feedback") — that's PR-description content, noise once merged.
- **TODO/FIXME markers** without an open tracker entry — open the ticket, fix it now, or accept it isn't getting fixed.
