# Testing Standards

**When to apply:** editing test files (`*.test.ts(x)`, `*.spec.ts(x)`).

- Use the project's existing test runner and patterns — don't introduce a new one.
- Test behavior, not implementation details.
- Mock external dependencies only (APIs, databases, file system) — not internal modules.
- Each test independent — no shared mutable state between tests.
- No hardcoded data coupled to environment — use factories or builders.
- `describe`/`it` names that read as sentences.
- Run the single relevant test file during development; full suite before declaring done.
- A flaky test gets fixed or removed, never ignored.
