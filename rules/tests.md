# Testing Standards

**When to apply:** editing test files (`*.test.ts(x)`, `*.spec.ts(x)`).

- Use the project's existing test runner and patterns — don't introduce a new one.
- Test behavior, not implementation details — a refactor that preserves behavior must not break the test. Heuristic: if you could rewrite the implementation and the test still passes for the wrong reason (or would pass against no implementation at all), it asserts nothing.
- Mock external dependencies only (APIs, databases, file system) — not internal modules.
- Each test independent — no shared mutable state between tests.
- No hardcoded data coupled to environment — use factories or builders.
- `describe`/`it` names that read as sentences.
- Run the single relevant test file during development; full suite before declaring done.
- A flaky test gets fixed or removed, never ignored. If it will not reproduce locally in ~3 attempts, stop looping the suite and **push it to CI** — a matrix leg on another OS often reproduces deterministically what your machine hides. Looping locally dozens of times is the expensive way to learn nothing.
- Assert on values normalised the way the code under test derives them. A test that compares a path must canonicalise it identically (`cd … && pwd`, not the raw `mktemp` string): `TMPDIR` may carry a trailing slash, so `mktemp -d "$TMPDIR/x"` can return a double slash that the code under test collapses. Environment shape — trailing slashes, temp dirs reached through a symlink, BSD vs GNU flags — is where "passes locally, fails on CI" comes from.
- E2E against shared state (PostHog sandbox flags, shared test accounts, seeded catalogs) may only mutate namespaced entities the test itself created (e.g. `e2e-*` prefixed), must never edit or select-by-fallback into real/shared entities, and must end by verifying the shared state is restored byte-identical. A conflict/deletion test needs an explicit re-select of its own entity — UI fallback selection after a delete is how a test silently edits the wrong record.
