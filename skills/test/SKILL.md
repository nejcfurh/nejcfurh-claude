---
name: test
description: Write tests with the right workflow — red-green-refactor for new features, prove-it for bug fixes. Invoke when the user says "write tests", "add tests", or "TDD".
---

Write tests for: $ARGUMENTS

## Pick the workflow

**New feature → red-green-refactor:**
1. RED — write a failing test that describes the desired behavior. Run it; confirm it fails for the right reason (not a typo or setup error).
2. GREEN — write the minimal implementation that makes it pass. Resist generalizing.
3. REFACTOR — clean up implementation and test while everything stays green.
4. Repeat per behavior.

**Bug fix → prove-it:**
1. Write a failing test that reproduces the bug BEFORE touching any fix.
2. If you can't write that test, you don't understand the bug yet — go back to investigating (use the `debug` skill), don't guess at a fix.
3. Fix the bug; the test goes green and stays as the regression test.

## Pick the test level

- **Unit** — pure logic: functions, reducers, utilities, business rules. Fast, no I/O.
- **Integration** — module boundaries: API routes, service + database, component + hooks. Real collaborators where practical.
- **E2E** — sparingly, only for critical user flows (signup, checkout, core happy path). Expensive and brittle; don't test edge cases here.

## Principles

- Test behavior, not implementation: assert on outputs, state, and observable effects — not internal calls, private methods, or mock plumbing. A refactor that preserves behavior should not break tests.
- Name tests after the behavior: "returns 404 when the user does not exist", not "test handleGet".
- Cover the unhappy paths: errors, empty inputs, boundaries — not just the happy path.
- Use the project's existing test runner and conventions; detect the package manager from the lockfile (npm/yarn/pnpm/bun).

## Running

- During development, run only the focused test file for a fast loop.
- Before declaring done, run the full suite — your change may break tests elsewhere.
