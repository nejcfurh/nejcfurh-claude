# TypeScript Standards

**When to apply:** editing `*.ts` / `*.tsx` files.

- No `any` — use proper types, generics, or `unknown` with narrowing at true boundaries.
- Prefer `const` over `let`, never `var`.
- Strict null checks — handle `null`/`undefined` explicitly; no non-null assertion (`!`), use narrowing or optional chaining.
- Prefer named exports over default exports.
- Prefer an options object when a function takes 3+ parameters or any optional/boolean parameter — avoid flag soup like `doThing(true, false)`. Exception: order-intuitive positional params (`clamp(value, min, max)`).
- Zod (or the project's validator) for runtime validation at system boundaries — API inputs, env vars, external data.
- Follow the project's formatter/linter config (Biome, ESLint, Prettier — whatever is configured); don't fight it.
