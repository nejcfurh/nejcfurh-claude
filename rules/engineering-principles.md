# Engineering Principles

**When to apply:** every implementation task.

## Change sizing

- Target small, reviewable commits (~100 lines); up to ~300 for cohesive changes that can't be split without losing context.
- 1000+ line changes must be split into sequential PRs or stacked commits.
- PRs touching 15+ files need a reason (rename/migration is fine; "I was in the area" is not).

## Vertical slicing

Implement features as thin end-to-end slices (UI + API + DB + test for one path), not horizontal layers ("all models first, then all routes"). If a slice is too large, narrow the scope — fewer fields, simpler validation.

## Chesterton's Fence

Before removing or changing existing code, understand why it exists: `git blame`, the introducing commit message, linked PRs. If no context exists and the code seems unnecessary, ask — don't silently remove.

## Shift left

Catch problems as early as possible: type system > lint > unit tests > integration tests > runtime validation > monitoring. If the type system can catch it, don't write a test for it — fix the types.

## Self-contained fallback and loading states

Anything meant to render before the rest of the page/app has finished loading — a loading spinner, a Suspense/skeleton fallback, a splash screen — must not depend on the assets it exists to cover for. Styling it with the same utility classes or stylesheet used everywhere else is the natural default, and it is wrong specifically here: under a slow connection there is no guarantee the stylesheet (or an animation's keyframes) has loaded by the time the fallback paints, so a stylesheet-dependent fallback can render as an invisible, unstyled element in the one place that can't assume its assets are present. Use inline styles for the properties that matter (colour, dimensions, border) and inline animation (a scoped `<style>` tag with `@keyframes`, not a utility animation class) for anything that must be visible from the very first paint. Once a loading state runs *after* the app has already hydrated and its stylesheet is already loaded, this no longer applies — style it normally.

## Grep before you build, grep before you're done

Two checks belong around every fix that targets a *pattern* rather than a single call site, and both are cheap enough to be no-excuse:

- **Before building:** grep for how the same *class* of problem is already solved elsewhere in the codebase before inventing a new mechanism for it. A codebase that already has an established fix for "this event must survive a page unload" or "this write must be idempotent" is telling you the shape of the fix it expects; building a fresh, undocumented approach next to three existing ones is how a review catches what a search would have.
- **Before declaring done:** grep the repo for the literal pattern you just fixed, not just the one file you noticed it in. A bug description phrased as "X does Y" is a search query, not just a diagnosis — sibling files (a paired error boundary, a duplicated handler, a copy-pasted route) routinely carry the identical defect, and fixing only the instance that was reported leaves the others live until someone else reports them too.

Both of these are the kind of miss an external review catches trivially and a five-second grep would have caught first.

## Blast radius on production

Before running or recommending a bulk operation — a backfill, migration loop, or mass API job — against a shared, rate-limited production resource (a live third-party API like Stripe, a DB connection pool), estimate peak load = concurrency × per-item fan-out and keep it a small fraction of the budget so customer-facing traffic isn't starved. Start conservative and ramp; never launch a prod batch at high concurrency. An admin/batch job must never degrade a customer path.

The same check applies below "bulk," not just above it. A single scripted or automated action that creates real records or triggers a real paid API call against shared infrastructure carries the same disclosure obligation as a bulk operation — the trigger is "does this have a real side effect," not "how many iterations." A preview or staging environment the user just stood up for testing is not exempt: it is still shared infrastructure with real downstream effects (database writes, third-party API costs), and "it's just for testing" is not the same as "nobody needs to know this happened." Flag it before the first run, not after several have already landed.

## Anti-rationalization

Never accept these shortcuts:

| Shortcut | Why it's wrong |
| --- | --- |
| Skip tests ("too simple to break") | Simple code becomes complex; the test catches the regression |
| `any` type ("fix later") | Later never comes; `any` spreads |
| Skip error handling ("can't fail") | Everything can fail |
| Hardcode values ("just for now") | Hardcoded values become permanent |
| TODO without a ticket | Dead code; ticket it or fix it now |
| Copy-paste with tweaks | Duplication diverges; extract or accept repetition consciously |

## Verifying a change

**A check must be derived independently of the change.** When you verify a bulk edit, a search-and-replace, or a delegated search, build the check from a different starting point than the edit — a different pattern shape, a different layer, or the rendered/deployed output rather than the source you touched. A grep that reuses the fix's own pattern, a test that asserts against the same constant the code maps over, and a delegate's search that pre-filtered out the files in question all share one failure mode: they confirm the assumption instead of testing the result, and they come back green. The check that finds the miss is almost always the one built a different way.

This is worse than an unverified change, because a green check gets reported as fact and is believed. Treat "I verified it" as a claim about the *method*, not the outcome: if the method could not have failed, it did not verify anything.

## Measuring a change

Applies whenever a number decides whether a change is good — perf work, output quality, anything tuned against a metric rather than a passing test.

- **Validate the metric before trusting it.** Run it on a known-good and a known-bad case first. A metric that cannot separate two cases whose answer you already know is an opinion, and it will happily justify the wrong change. Smoothness metrics reward blurring, coverage metrics quietly measure the wrong denominator — the failure is silent either way.
- **The user's direct observation outranks the metric.** If someone looks at the output and says it got worse while the number says better, the number is wrong until proven otherwise. Go find what it is failing to capture.
- **Two numbers are only comparable if they were computed the same way.** Before setting a fresh measurement against an existing figure — a documented baseline, a number in a ticket, last quarter's result — confirm both share a denominator, a population and a time window. A raw event count is not a per-user rate; a one-week slice is not a 90-day one; an unfiltered query is not one that excludes test accounts. Getting this wrong produces a confident "it's actually X, not Y" that reframes the problem and can redirect real work. If you cannot reconcile the two, report the new number with its definition stated and say the comparison is unavailable — that is more useful than a delta nobody can trust.
- **Change one variable per measurement.** Two changes measured together give a delta you cannot attribute, and the improvement gets credited to whichever one you were hoping for.
- **A commit justified by a measurement contains only what was measured.** Bundling an unmeasured change alongside is how a change already measured as *worse* ships anyway.
- **A measurement that says "worse" is a result, not a setback.** Revert it there and then. Do not carry it forward hoping a later change compensates.
- **A test that encodes a product judgment is a metric, and gets validated like one.** When an assertion says a *behaviour* is correct ("one result here is the right number"), that claim came from you, not from the code — writing it down does not make it true, it freezes it. Check it against real data first. This is the most dangerous failure mode on the list, because the suite goes green and every later review reads the assertion as the specification.

## Exploration guard rails

For open-ended tasks, explore briefly, then start writing code — partial progress beats perfect plans. Never spend an entire session on analysis without producing a working artifact.

Producing one artifact does not buy unlimited exploration afterwards. Investigation is easy to continue one cheap-sounding step at a time while the total quietly runs into hours, and the next step always looks affordable in isolation. After a few rounds with nothing further shipped, state the cumulative cost and what is left untested, and ask whether to continue — rather than offering the next step as though it were the first.
