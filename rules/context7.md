---
alwaysApply: true
---

When working with libraries, frameworks, or APIs — use Context7 MCP to fetch current documentation instead of relying on training data. This includes setup questions, code generation, API references, and anything involving specific packages.

The server's own instructions cover when to reach for it and the call sequence — don't restate them here. Two things they leave out: when resolving a library, prefer exact names and version-specific IDs if a version is in play; and cite the version in the answer, so a future reader knows which docs it came from.

If the MCP server is unavailable or returns nothing, fall back to the `/find-docs`
skill, which reaches the same source through the Context7 CLI. That skill is
manual-invocation only, so this rule stays the single automatic path.
