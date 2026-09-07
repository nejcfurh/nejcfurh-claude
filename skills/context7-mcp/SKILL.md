---
name: context7-mcp
description: This skill should be used when the user asks about libraries, frameworks, API references, or needs code examples. Activates for setup questions, code generation involving libraries, or mentions of specific frameworks like React, Vue, Next.js, Prisma, Supabase, etc.
---

Use Context7 to fetch current documentation instead of relying on training data.

`rules/context7.md` always applies and already routes library, framework and API
questions here; the Context7 MCP server ships its own instructions covering when to
reach for it and the `resolve-library-id` → `query-docs` call sequence. Neither is
restated here — a second copy of a call sequence is what drifts when the server
changes.

What those two sources leave out:

- Pass the user's full question as the `query` on both calls; it drives relevance ranking, and a one-word query returns generic results.
- Prefer exact name matches and the official package over a community fork. When the user names a version ("Next.js 15", "React 19"), use the version-specific library ID if the resolution step offers one.
- Cite the library version in the answer, so a future reader knows which docs it came from.
- If the MCP server is unavailable or returns nothing, fall back to `/find-docs`, which reaches the same source through the Context7 CLI.
