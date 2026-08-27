# Engineering Principles

**When to apply:** every implementation task.

## Change sizing

- Target small, reviewable commits (~100 lines); up to ~300 for cohesive changes that can't be split without losing context.
- 1000+ line changes must be split into sequential PRs or stacked commits.
- PRs touching 15+ files need a reason (rename/migration is fine; "I was in the area" is not).
- Past ~30 files or ~1000 lines, the answer is a **stack**, not a bigger PR — and so it is whenever new work depends on a PR that is already open. Reviewability is the constraint being optimised, not PR count. Mechanics, slicing order and the seam test: `git-conventions.md`.

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

## Copying data is a disclosure decision

Pulling a dataset out of a shared environment onto someone's machine is its own decision, separate from whatever you needed it for, and it is made on what the data *contains* — so find out before describing it.

**A schema-scoped export is not a PII-scoped export.** Excluding an auth or identity schema does not make an extract clean: application tables carry their own email, name, phone and address columns, and audit or event-log tables are usually the worst offenders because nobody thinks of them as customer data. Enumerate the columns (`information_schema.columns` filtered on the obvious names) and grep the produced file before making any claim about what is in it. Never present a scoping choice as a privacy guarantee it does not provide — if someone accepts a copy because you said it carried nothing sensitive, an inaccurate summary has made that decision for them on false terms. State what it does contain, where it landed, and that it is ignored by version control rather than absent from disk.

Prefer the least-sensitive source that answers the question, and prefer a target you can name over a whole-schema sweep. When the data is only needed to make a screen render, a synthetic fixture beats a real extract and needs no disclosure at all.

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

## A noticed concern is a debt, not a thought

The most expensive misses are rarely the ones you failed to see. They are the ones you *did* see, phrased to yourself as "worth checking" or "I'll note that in the write-up", and then never discharged. The noticing feels like handling it, so the item is silently marked done and the work ships without it — and because you already considered it, you will not reconsider it.

Two shapes, both costly:

- **A check you decided to run.** Run it then, or say out loud that you skipped it and why. "I should confirm nothing else is using this before I overwrite it" is worthless one command later, once the damage is done.
- **A trade-off you decided to record.** Put it in the artifact — the PR body, the ticket, the handover — at the moment you notice it, not at the end. A caveat that lives only in your reasoning does not exist for anyone else, and a reviewer finding it later reads as you having hidden it rather than having weighed it.

Treat "I'll come back to that" as a commitment with no scheduler behind it. Either do it now, write it into the artifact now, or state plainly that you are not doing it.

## Verifying a change

**A check must be derived independently of the change.** When you verify a bulk edit, a search-and-replace, or a delegated search, build the check from a different starting point than the edit — a different pattern shape, a different layer, or the rendered/deployed output rather than the source you touched. A grep that reuses the fix's own pattern, a test that asserts against the same constant the code maps over, and a delegate's search that pre-filtered out the files in question all share one failure mode: they confirm the assumption instead of testing the result, and they come back green. The check that finds the miss is almost always the one built a different way.

This is worse than an unverified change, because a green check gets reported as fact and is believed. Treat "I verified it" as a claim about the *method*, not the outcome: if the method could not have failed, it did not verify anything.

**Proving a new test can fail requires a harness valid for BOTH versions.** Running a fresh test against the pre-change code is the right instinct — a test that passes before and after asserts nothing about the change. But the run only means something if the *only* difference is the code under test. Point a new test at the old implementation and it will often fail for a reason that has nothing to do with behaviour: a mock or stub written against the new module's imports, a helper or fixture that did not exist yet, a renamed export. That is a red result you have not earned, and it reads exactly like the proof you wanted. Before believing a red, read the failure message: an import, type or "not a function" error is a broken harness, not a behavioural difference. Fill in whatever the old version needs — stubbed to what production actually does — and re-run. This cuts both ways: for a change that is deliberately behaviour-neutral, a test passing against *both* versions is the proof, and the same broken harness would have shown five confident failures instead.

**Revert a deliberate mutation from a snapshot you took, not from version control.** `git checkout -- <path>` restores what is *committed*, which is neither the file you created and have not committed nor the unrelated uncommitted edits sitting in the same path — it discards both, reports nothing, and the next mutation then stacks on a tree you no longer recognise. Attribution is gone at that point even though every round still produces a plausible-looking failure. `cp` the files aside before the first mutation and copy them back between rounds, and diff against the snapshot at the end to prove the tree came home.

**A command's exit status is not the pipeline's.** `cmd | tail -n5` reports *tail's* status, so an `echo "exit:$?"` after it prints success however `cmd` failed — and a `--quiet`/`--silent` flag suppresses the error text that would have given it away. Together they make a check that cannot fail: green for a command that did nothing. Confirm an install, build or migration from the **artifact** it was supposed to produce — the directory is populated, the binary resolves, the row exists — not from a status read through a pipe. This matters most for setup steps whose failure surfaces later and somewhere else: a dependency tree that never installed reappears as a wall of unrelated compile errors, and the wrong thing gets debugged. It matters more again when the result is handed to someone else, including a delegated agent, who will build on the claim rather than re-check it.

**A callback you hand to a dependency runs under that dependency's error handling, not yours.** Before adding a function to a third-party extension point — a before-send style filter, a request interceptor, a lifecycle hook, a custom serializer — read the call site in the *installed* package and find out whether the host wraps it. Many do not: the call is bare, so one throw from your function takes out everything downstream of it, which is almost always far wider than the feature you were adding. Two things follow. Size the blast radius from the call site, not from your function's purpose — a hook on a general event path is not scoped to the events you care about. And where the host does not guard the call, make the function fail open and prove it with hostile inputs: nulls, wrong types and missing keys at every level the payload nests. "I traced the branches and there is no throw path" is a deduction about your reading, and the payload's shape belongs to the dependency, which is free to change it.

**Authoring a file through the shell bypasses whatever the editor tools trigger.** Projects commonly hang formatting, linting or codegen off file-editing tool calls. Creating the same file with a redirect, a heredoc or a generator script is invisible to those hooks, so it lands unformatted and the omission surfaces much later — at a pre-push gate, or in CI, on a branch you believed was clean. When a project formats or lints on edit, run its formatter explicitly over anything you produced outside the edit tools before staging it.

## Measuring a change

Applies whenever a number **or a verdict** decides whether a change is good — perf work, output quality, anything tuned against a metric rather than a passing test, and any script that sweeps for a condition and reports what it found.

- **Validate the metric before trusting it.** Run it on a known-good and a known-bad case first. A metric that cannot separate two cases whose answer you already know is an opinion, and it will happily justify the wrong change. Smoothness metrics reward blurring, coverage metrics quietly measure the wrong denominator — the failure is silent either way.
- **A checker is a metric.** A script that reports "this string is absent", "no call sites remain", "nothing matched" is measuring, and gets the same known-good case first: point it at something you can see with your own eyes and confirm it says *present*. Its false negatives are the dangerous half — an empty finding list reads as diligence, and nothing about a clean report distinguishes "nothing is wrong" from "the check could not see". A checker that has only ever returned findings you liked has not been validated; it has been agreed with.
- **Establish that a movement is real before investigating its cause.** A number that moved is not yet a finding: at small per-bucket counts, swings of ±25% between adjacent days or segments are ordinary. Size the noise first, then hunt. Ruling out five mechanisms for something that never exceeded noise is the most expensive route to "it was nothing" — and the investigation itself lends the number false credibility, because each eliminated cause makes the movement feel more established when nothing has been established at all.
- **An aggregate can be significant while every component of it is noise.** Split any headline result by the dimensions the change actually acts on, and by time, before believing it. Components that all sit near the threshold and flip sign between adjacent periods are independent wobbles that happened to align once; the aggregate crossed the line because several of them pointed the same way in the same bucket. This matters most when the aggregate mixes populations the change treats differently — then it silently conflates "did the change work" with "did it cover the same ground", and the split answers both.
- **When a metric looks wrong, check the metric's configuration before changing the code it measures.** A missing signal, a population that should not be there, a number that cannot be right — far more often the measurement's own setup (which event it counts, how it handles duplicates, which environment it reads) than the instrumented code. Planning a refactor from the symptom skips the cheapest explanation and risks rewriting working code to satisfy a misconfigured reading.
- **The user's direct observation outranks the metric.** If someone looks at the output and says it got worse while the number says better, the number is wrong until proven otherwise. Go find what it is failing to capture.
- **Two numbers are only comparable if they were computed the same way.** Before setting a fresh measurement against an existing figure — a documented baseline, a number in a ticket, last quarter's result — confirm both share a denominator, a population and a time window. A raw event count is not a per-user rate; a one-week slice is not a 90-day one; an unfiltered query is not one that excludes test accounts. Getting this wrong produces a confident "it's actually X, not Y" that reframes the problem and can redirect real work. If you cannot reconcile the two, report the new number with its definition stated and say the comparison is unavailable — that is more useful than a delta nobody can trust.
- **Change one variable per measurement.** Two changes measured together give a delta you cannot attribute, and the improvement gets credited to whichever one you were hoping for.
- **A commit justified by a measurement contains only what was measured.** Bundling an unmeasured change alongside is how a change already measured as *worse* ships anyway.
- **A number written into a durable artifact is held to a higher bar than one said in passing.** Tickets, write-ups, PR bodies, dashboards and docs are quoted onward long after the caveats are lost, and correcting one costs more than the original claim earned. Decompose it first, or write the range and the method instead of the point estimate.
- **A measurement that says "worse" is a result, not a setback.** Revert it there and then. Do not carry it forward hoping a later change compensates.
- **A rule set that classifies real data is derived from that data, never from a description of it.** Filters, matchers, parsers and heuristics written from a ticket's prose, a remembered payload shape or an upstream changelog will miss the cases nobody thought to describe — and they pass their tests, because the fixtures were invented from the same guess. Pull a representative sample first and group it by frequency so you can see what actually dominates; write the patterns against that, and build the fixtures from real records, deliberately including the ones that must *not* match. A classifier whose suite contains no real input has been specified, not verified. The sample is also the only way to catch the inverse error: a pattern that looks precise but matches nothing, because the real strings are shaped differently than the description implied.
- **A test that encodes a product judgment is a metric, and gets validated like one.** When an assertion says a *behaviour* is correct ("one result here is the right number"), that claim came from you, not from the code — writing it down does not make it true, it freezes it. Check it against real data first. This is the most dangerous failure mode on the list, because the suite goes green and every later review reads the assertion as the specification.

## Exploration guard rails

For open-ended tasks, explore briefly, then start writing code — partial progress beats perfect plans. Never spend an entire session on analysis without producing a working artifact.

Producing one artifact does not buy unlimited exploration afterwards. Investigation is easy to continue one cheap-sounding step at a time while the total quietly runs into hours, and the next step always looks affordable in isolation. After a few rounds with nothing further shipped, state the cumulative cost and what is left untested, and ask whether to continue — rather than offering the next step as though it were the first.
