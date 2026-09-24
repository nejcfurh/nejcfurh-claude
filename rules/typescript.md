# TypeScript Standards

**When to apply:** editing `*.ts` / `*.tsx` files.

- No `any` — use proper types, generics, or `unknown` with narrowing at true boundaries.
- Prefer `const` over `let`, never `var`.
- Strict null checks — handle `null`/`undefined` explicitly; no non-null assertion (`!`), use narrowing or optional chaining.
- Prefer named exports over default exports.
- Prefer an options object when a function takes 3+ parameters or any optional/boolean parameter — avoid flag soup like `doThing(true, false)`. Exception: order-intuitive positional params (`clamp(value, min, max)`).
- Zod (or the project's validator) for runtime validation at system boundaries — API inputs, env vars, external data.
- Follow the project's formatter/linter config (Biome, ESLint, Prettier — whatever is configured); don't fight it.
- **A clean lint is not evidence that a symbol resolves.** `no-undef` is disabled in every standard TypeScript lint preset, because resolution is the typechecker's job — so a name you used but never imported passes lint silently and fails only under `tsc`. The trap is that the linter is the fast check and the one wired into edit-time hooks, so a green run right after an edit reads as "that compiles". It doesn't: it says the *style* is fine. Whenever an edit introduces a new identifier — a constant, a helper, a type, anything capitalised you did not type an import for — run the typechecker before believing the edit, and treat a lint pass that follows an added symbol as unverified. The same gap swallows a symbol left behind after a refactor removes its last use; there lint *does* fire (`no-unused-vars`), which is the asymmetry that makes the first case easy to trust.
