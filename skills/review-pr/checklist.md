# PR review checklist

## Correctness

- [ ] Edge cases handled: empty collections, zero, negative numbers, missing/undefined values, unicode.
- [ ] Error paths: what happens when the fetch fails, the promise rejects, the input is malformed?
- [ ] Race conditions: concurrent requests, stale closures, un-awaited async, double-submits.
- [ ] Off-by-one: loop bounds, slice/substring indices, pagination cursors, inclusive vs exclusive ranges.

## Type safety

- [ ] No `any` (including implicit `any` and `as any` escapes); use `unknown` + narrowing where the type is truly open.
- [ ] `null`/`undefined` handled where values can be absent — no unjustified `!` assertions.
- [ ] External data validated at boundaries (API responses, request bodies, env vars) — not just cast to an interface.

## Tests

- [ ] Tests exist for the changed behavior.
- [ ] They test behavior (inputs → observable outputs), not implementation details or mock choreography.
- [ ] They would actually fail if the change regressed — not vacuous assertions or over-mocked shells.

## Security

- [ ] No injection vectors: string-built SQL, shell interpolation, unsanitized HTML/dangerouslySetInnerHTML.
- [ ] New endpoints/surface verify both authentication and authorization.
- [ ] No secrets or credentials introduced in code, config, or logs.
- [ ] No unsafe deserialization or eval of untrusted input.

## Performance

- [ ] No N+1 queries (query inside a loop, per-item fetches that could be one query).
- [ ] Result sets bounded: pagination or limits on list queries.
- [ ] Work in loops that could batch: bulk inserts, Promise.all over sequential awaits (where safe).
- [ ] React: no unnecessary re-renders — unstable deps, objects/functions recreated per render passed to memoized children, missing keys.

## Scope

- [ ] The diff matches the PR's stated intent — everything in it belongs to it.
- [ ] No drive-by refactors, dependency bumps, or formatting churn hiding among real changes.

## Readability

- [ ] Names say what things are; no misleading or vestigial names left from earlier drafts.
- [ ] No dead code, commented-out blocks, or leftover debug statements.
- [ ] Comments explain WHY (constraints, non-obvious decisions), not WHAT the code plainly does.
