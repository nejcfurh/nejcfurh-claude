# Engineering Principles

**When to apply:** every implementation task.

## Change sizing

- Target small, reviewable commits (~100 lines); up to ~300 for cohesive changes that can't be split without losing context.
- 1000+ line changes must be split into sequential PRs or stacked commits.
- PRs touching 15+ files need a reason (rename/migration is fine; "I was in the area" is not).
- Past ~30 files or ~1000 lines, or when new work depends on an open PR, use a **stack**, not a bigger PR: reviewability is the constraint, not PR count. Mechanics: `git-conventions.md`.

## Branching complexity

Cyclomatic complexity = decision points + 1 (each `if`, `else if`, `case`, loop, `catch`, ternary, and `&&`/`||` in a condition). **The project's own threshold wins** (eslint `complexity`, radon, sonar, `gocyclo` in CI). Absent one: 1-5 fine, 6-10 refactor if already in the file, 11-15 refactor now, past 15 split before the change lands.

Measure; the eyeballed estimate runs low: `radon cc -s -a <path>` (Python), `gocyclo <path>` (Go), `lizard <path>` (most else), eslint's `complexity` rule (JS/TS; the one-off `--rule` form differs between eslint 8 and flat config). With no tool, count by hand per function and show it.

Tactics, in order: guard clauses that return early; extract a function named for *what*, not *how*; a lookup table for an if-else or switch chain; a named predicate for a four-clause boolean; extract the loop body and `continue`. Strategy or polymorphism for a switch-on-type only once the same switch is in two or more places.

**Don't game the metric**: complexity moves into named units, never into a dense one-liner. **The count triggers a look, never a verdict**: splitting a linear dispatch into six functions lowers it and can hurt the reader.

Lowering a count is behaviour-neutral, so existing tests pass against **both** versions (`tests.md`); an untested refactor gets a test first or stays small enough to read in one sitting. Never change an exported signature to lower a count without asking. An over-threshold function the task does not otherwise touch is a PR-body note, not an edit. A before/after count in a PR body falls under *Measuring a change*, including reverting when the result reads worse.

## Vertical slicing

Implement features as thin end-to-end slices (UI + API + DB + test for one path), not horizontal layers. If a slice is too large, narrow the scope: fewer fields, simpler validation.

## A handed file may be a model, not the target

When a request supplies standalone artifacts (a mockup, an exported page, a prototype, a design file) and the working directory is a codebase, establish which is the deliverable **before editing either**. Paths in the prompt are often only the reference. The tell: a sentence that puts the thing elsewhere ("the design we have in the app", "match what's live"); one search for the artifact's distinctive strings settles it. Editing the wrong one fails nothing, because the file is in no build.

## Chesterton's Fence

Before removing or changing existing code, understand why it exists: `git blame`, the introducing commit, linked PRs. If no context exists and the code seems unnecessary, ask; don't silently remove.

**The fence cuts the other way too: an exception to a standing rule is a fence with a date on it.** A runbook step, comment or test assertion granting an exception ("changed by hand in production", "skipped here") is often left over from a closed migration. Before following one, read its provenance (blame, introducing change, named ticket). When it contradicts a standing rule, ask the rule's owner which is current. Never hand the forbidden action to a person able to do it: that routes around the rule and writes a stale procedure into a ticket.

## Shift left

Catch problems as early as possible: type system > lint > unit tests > integration tests > runtime validation > monitoring. If the type system can catch it, fix the types instead of writing a test.

**A missing config value must never silently select the branch that disables the feature.** A kill switch, sampling flag or "only outside local development" guard that falls back to off when unset ships inert, and a disabled feature emits nothing to notice. Fail loudly at startup or default to the branch whose wrongness is visible, and have the deploy set the value. A gate copied from elsewhere brings its env vars: port the deployment config in the same change and read back what the running build resolved. A value that selects an environment (a store, an API, a database) gets no default, or every unconfigured build acts on production; missing, it fails at startup.

## Self-contained fallback and loading states

Anything that renders before the page/app finishes loading (spinner, Suspense/skeleton fallback, splash screen) must not depend on the assets it covers for: at first paint on a slow connection the stylesheet or keyframes may be missing, and a utility-styled spinner renders invisible. Use inline styles for what matters (colour, dimensions, border) and a scoped `<style>` tag with `@keyframes`, not a utility animation class. After hydration, style it normally.

## Grep before you build, grep before you're done

Around every fix that targets a *pattern* rather than one call site:

- **Before building:** grep for how the same *class* of problem is already solved ("must survive a page unload", "must be idempotent"). That is the shape the codebase expects; a new mechanism beside three existing ones is what a reviewer catches.
- **Before declaring done:** grep for the literal pattern you fixed. Siblings (a paired error boundary, a duplicated handler, a copy-pasted route) routinely carry the same defect.

**Grep the history too, when the thing you are adding used to exist.** Restoring behaviour a recent rewrite removed (a link, badge, field, tracking parameter): the deleted implementation is the specification, with decisions the request will not restate. Find it (`git log --diff-filter=D -- <area>`, or the `--stat` of the merge you pulled), read it first, and say which decisions you kept. Mirror case: reverting a file to its pre-feature version also reverts unrelated fixes made meanwhile; diff the two and keep what the feature did not own.

**The same history read comes before proposing a fix for a regression.** When `git log -S` or blame shows the mechanism arrived with a recent rewrite, read the version before it: what the rewrite removed is the first, usually simplest, fix candidate.

**The same check applies before scripting against the project's own systems** (a sign-in, a fixture, a token, a test double). The project's test helpers hold the working sequence; read them before upstream docs. Each wrong guess costs a round and looks like a product bug (a redirect to sign-in, an empty render, a 401).

**The file you copied from is one sample, not the convention.** List every sibling solving the same problem and follow the majority; where they disagree, prefer the newest and most-depended-on. It matters most where nothing fails visibly (config validation, throw vs return empty, missing-value defaults).

## Blast radius on production

Before running or recommending a bulk operation (backfill, migration loop, mass API job) against a shared, rate-limited production resource (a live third-party API like Stripe, a DB connection pool), estimate peak load = concurrency × per-item fan-out and keep it a small fraction of the budget. Start conservative and ramp; a batch job must never degrade a customer path.

The trigger is a real side effect, not the iteration count: one scripted action that creates real records or makes a paid API call on shared infrastructure counts, and a freshly stood-up preview or staging environment is not exempt. Flag it before the first run. Driving a local app counts: before its first write, read the backend it resolved from its own output (a host in a returned link), never from the env file you expect it to load.

**Pilot every item of a batch once before running the batch.** Before fanning out N slow or quota-drawing runs (headless sessions, CI jobs, paid API calls), run each distinct item once and read its duration, output size and result shape. One runaway or meaningless item otherwise costs the whole batch.

## Copying data is a disclosure decision

Pulling a dataset out of a shared environment onto someone's machine is its own decision, made on what the data *contains*; find out before describing it.

**A schema-scoped export is not a PII-scoped export.** Application tables carry their own email, name, phone and address columns; audit and event-log tables are usually the worst. Enumerate the columns (`information_schema.columns` on the obvious names) and grep the produced file before claiming anything. Never present a scoping choice as a privacy guarantee. State what it contains, where it landed, and that it is ignored by version control, not absent from disk. Prefer the least-sensitive source and a named target; if the data only needs to make a screen render, use a synthetic fixture.

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

A concern you noticed ("worth checking", "I'll note that") feels handled, and you will not reconsider it. Discharge it:

- **A check you decided to run.** Run it then, or say you skipped it and why.
- **A trade-off you decided to record.** Put it in the artifact (PR body, ticket, handover) when you notice it; a caveat that lives only in your reasoning reads as hidden when a reviewer finds it.

"I'll come back to that" is a commitment with no scheduler behind it.

**Route the debt by ownership.** A concern about work the current task does not own goes where that work will be picked up (its ticket, its notes, the memory entry), not to the user; escalating it mid-task is scope drift. Housekeeping (tidying notes, indexes, docs) is where this bites. Raise it in conversation only when it blocks the current task or is time-critical, and verify it to the task's standard first.

## Verifying a change

**Closing an item as already-done is a claim about scope, not just presence.** That the named change landed (version bumped, commit merged, flag flipped) says nothing about coverage: both surfaces, every caller, every environment. Verify the scope the closure note will claim; it reads to the next person as a verified finding.

**A gate you add is verified through the path that actually invokes it, and priced before it ships.** A suite that calls the guard directly can pass on a version that never fires: hand-built inputs encode the cwd, argument form and environment where guards fail open. Drive it once end to end from the real entry point with a case that must be refused; a guard that should have blocked returns the operation's own output, which reads as success. Then price it: route it under the condition it checks and measure the per-call difference on its dispatcher.

**Spending one of several independent locks is a trade, never a free simplification.** When safety rests on two things at once (a narrow flag *and* an unset switch, a code guard *and* an unissued credential) and a change spends one ahead of need, say which single point of failure the remaining one now is, and prefer splitting the change so each lock is spent when required.

**Launch readiness includes the words.** Check every sentence the user reads (UI, email, brief) against what the test run did, on each branch of the logic. A test observation that contradicts the copy is a defect even when it matches the code. A plan item marked unresolved blocks readiness until its owner decides.

**A check must be derived independently of the change.** Build it from a different starting point: a different pattern shape, a different layer, or the rendered/deployed output instead of the source you touched. A grep reusing the fix's own pattern, a test asserting the constant the code maps over, or a delegate's search that pre-filtered out the files in question confirms the assumption and comes back green.

**An enumeration that backs a go/no-go is produced by a command, not by recall.** "Everything this change does in production", "the files affected": derive the list from the diff, then classify every entry against the claim (gated or not, reachable or not). The item you judged minor earlier is the one recall drops.

**Truncated output is a partial read — re-query, don't report it.** Project fewer columns, filter to the rows in question, or aggregate. The unread cell is where a difference hides.

**Never state what CI does or does not run without reading the trigger.** Jobs are narrowed by branch and path filters, `workflow_dispatch`-only triggers and `if:` conditions; read the trigger block against `git diff --name-only`. Prefer reporting the checks you actually saw on the PR.

**A default-UA fetch is not what a user receives.** Servers branch on the user agent (bot detection, analytics suppression, different markup), so "absent from the HTML" is no evidence until the request carried a real browser UA. Inversely, a value the page consumes at runtime reads as missing after load. Check the served document for what the server sent and the live DOM for what survives.

**Migrating literals into an indirection layer needs a reachability check, not an equivalence check.** When strings, numbers or settings move behind a lookup (message dictionary, flag registry, config map, theme table), the failure is a **key created but never wired**: the call site keeps the literal, so the old surface still renders the same. Parse the keys out of the lookup, grep each against its own source file, and treat any with no reference as unmigrated (confirm computed or templated keys).

**Proving a new test can fail requires a harness valid for BOTH versions.** Run it against the old code, with the code under test as the *only* difference. An import, type or "not a function" error is a broken harness (a mock of the new module's imports, a missing fixture, a renamed export), not a behavioural difference: fill in what the old version needs, stubbed to production behaviour, and re-run. For a behaviour-neutral change, passing against both versions is the proof.

**Revert a deliberate mutation from a snapshot you took, not from version control.** `git checkout -- <path>` restores the committed state and silently discards uncommitted new files and unrelated edits in that path. `cp` the files aside before the first mutation, copy them back between rounds, and diff against the snapshot at the end.

**Confirm an install, build or migration from the artifact it produces, not from an exit code**: the directory is populated, the binary resolves, the row exists.

**When an asset grows, measure what the user downloads.** A higher-resolution source or a full-size render reused as a thumbnail multiplies page weight and fails no check. Report served bytes per asset before hand-off, and size thumbnails to their display width.

**A callback you hand to a dependency runs under that dependency's error handling, not yours.** Before adding a function to a third-party extension point (before-send filter, request interceptor, lifecycle hook, custom serializer), read the call site in the *installed* package: if it does not wrap your function, one throw takes out everything downstream. Size the blast radius from the call site, not from your function's purpose. Make it fail open and prove it with hostile inputs: nulls, wrong types, missing keys at every nesting level.

**Patching a global is invisible to any consumer that already captured the reference.** Libraries bind `fetch`, `XMLHttpRequest`, `setTimeout` or a logger at bundle evaluation, so a later reassignment (console snippet, test hook, probe) is never consulted; prototype methods and per-call lookups still intercept. Read how the installed package takes the reference first. Validate an interceptor with traffic the dependency itself generates; a hand-made request proves only the parser.

**A state occurring a few dozen times a day across a whole population will not reproduce to order.** Estimate the hit probability (occurrences per day against traffic, times your attempts) before a hunt that depends on landing in it. When small, instrument the population instead: ship an assertion that reports the state wherever it happens, and read it a day later.

**A recording, log or dump you were handed is a measuring instrument — exhaust it before building a reproduction.** Timestamps, pixel coordinates, ordering and exact values fitted against what the code intended often name the fault outright (a constant scale factor, a fixed offset, an off-by-one interval) for the cost of one script.

**A report's "it worked before X" is a search constraint, so check it before it steers anything.** One `git log -L` over the lines producing the symptom says whether they moved. If not, the cause is environmental, and theories about a recent change are dead. The reporter says when *they* noticed, not when the behaviour changed.

**"It happens on X but not on Y" is the experiment, already designed.** The cause is whatever differs between them: diff the pair first (the two screens' props, configs, environments). The discriminator often arrives as a parenthetical aside.

**Establish the request path before theorising about the origin.** A fault on one hostname and not another is a claim about the *route*: a CDN, WAF or proxy can alter or reject a request the origin handles fine, and the repo does not record it (the tell is a vendor header nobody deployed). Repeat the identical request straight to the origin (`curl --resolve <host>:443:<origin-ip> …`); if it succeeds there, the application is exonerated.

**Consistency is not correctness — establish the current value is wrong before changing it to match.** Matching the neighbours is a check that cannot fail, and cannot tell a defect from a deliberate exception (a size tuned for that surface, a requested spacing). Say what is *wrong* with the value and where you observed it; if it only differs, the case is not made.

**Modifying an existing file is a different act from creating one, and the shell is the wrong default for it.** Heredocs and inline scripts suit new files, large payloads and batches. For a few lines in an existing file, prefer the editing tools, which fail loudly on an ambiguous or unmatched target; a shell rewrite fails *plausibly* (a capture group one line too far, the wrong one of two similar blocks, dropped closing lines), and a replacement that matches nothing exits cleanly and prints nothing. The target also goes stale between read and replace (an on-edit hook rewrote it, or you typed the old value from memory). Where the shell is right, address by line, snapshot first, read the result back, and treat "no output" as unproven. Either way, confirm the file still parses.

**Never assume the shell's working directory — write paths that do not depend on it.** Whether a `cd` persists differs by harness. Use absolute paths, or `cd` in the same command; in a repo, `git -C <path>`. A command handed to the user needs the same. Where the cwd matters, print it.

**zsh is not bash about variables, and the difference fails quietly.** An unquoted `$var` holding spaces is *not* word-split (`set -- $pair` yields one argument); use `${=var}`. `$name:x` applies a history modifier (`$2:rate` is `$2` with its extension stripped, then `ate`); brace every variable a colon follows: `${2}:rate`. When a scripted sweep returns identical readings for every case, check the loop variables first. Quote a glob in an argument (`--include=*.ts`): unmatched, it aborts with `no matches found`. Quote a bare word starting with `=`: `echo ===` aborts with `== not found`.

**A heredoc is only literal when its delimiter is quoted.** `<<EOF` runs backticks and substitutes `$name` in the body; write `<<'EOF'` whenever the body is meant verbatim.

**Chain dependent shell steps with `&&`, never `;` or a newline.** When the preparing step fails (a patch script, a build, a fetch), a `;`-chained capture, publish or test still runs on stale input and reports success.

## Measuring a change

Applies whenever a number **or a verdict** decides whether a change is good: perf work, output quality, anything tuned against a metric, and any script that sweeps for a condition and reports what it found.

- **Validate the metric before trusting it.** Run it on a known-good and a known-bad case first; a metric that cannot separate them is an opinion (smoothness metrics reward blurring, coverage metrics measure the wrong denominator).
- **A checker is a metric.** A script reporting "absent", "no call sites remain", "nothing matched" is measuring: point it first at something you can see and confirm it says *present*. A clean report cannot distinguish "nothing is wrong" from "the check could not see".
- **Search for something only your change could have produced.** Ordinary tokens already exist, so the search succeeds when nothing was rebuilt. Pick a string unique to the change and confirm the string it *replaced* is gone. Match the emitted form (build steps escape, rename, minify, split) and read the artifact the consumer actually loads.
- **Establish that a movement is real before investigating its cause.** At small per-bucket counts, ±25% between adjacent days or segments is ordinary. Size the noise first, then hunt.
- **An aggregate can be significant while every component of it is noise.** Split a headline result by the dimensions the change acts on, and by time. Components near the threshold that flip sign between adjacent periods are wobbles; an aggregate mixing populations the change treats differently conflates "did it work" with "did it cover the same ground".
- **When a metric looks wrong, check the metric's configuration before changing the code it measures**: which event it counts, how it dedupes, which environment it reads.
- **A value your own harness wrote is not an observation.** Probes, fixtures and repro scripts mutate what they inspect (seed a field, clear a key, stub a getter). Name who last wrote a value before it becomes a finding; re-derive from an untouched path.
- **The user's direct observation outranks the metric.** If they say it got worse while the number says better, the number is wrong until proven otherwise; find what it fails to capture.
- **Two numbers are only comparable if they were computed the same way.** Confirm a shared denominator, population and time window (a raw count is not a per-user rate; a week is not 90 days; unfiltered is not test-accounts-excluded). If you cannot reconcile them, report the new number with its definition and say the comparison is unavailable.
- **Change one variable per measurement.** Two changes measured together give a delta you cannot attribute.
- **A commit justified by a measurement contains only what was measured.**
- **A number written into a durable artifact is held to a higher bar than one said in passing.** Tickets, PR bodies and dashboards are quoted without their caveats: decompose it first, or write the range and the method.
- **A measurement that says "worse" is a result, not a setback.** Revert it there and then; do not hope a later change compensates.
- **A rule set that classifies real data is derived from that data, never from a description of it.** Filters, matchers, parsers and heuristics written from a ticket or changelog miss undescribed cases and pass fixtures invented from the same guess. Pull a representative sample, group it by frequency, write the patterns against it, and build fixtures from real records, including ones that must *not* match.
- **A value read off one instance cannot tell you whether it is absolute or derived** (exactly half its container looks like a ratio; a ratio on a round number looks like a constant). Check a second instance at a different size; with only one, implement the reading that degrades safely (a cap rather than a hard size) and state the assumption where the next reader will meet it.
- **A test that encodes a product judgment is a metric, and gets validated like one.** An assertion that a *behaviour* is correct ("one result here is the right number") is your claim, frozen; check it against real data first, because later reviews read it as the specification.

**Under an unknown cause, prefer the fix that removes the failing component to the one your theory predicts.** A theory-derived remedy inherits the theory's uncertainty, costs a deploy per attempt, and its failure cannot say which premise was wrong. Say which kind you propose: one that depends on the diagnosis, or one that holds whichever diagnosis is right (route around the failing component, switch off the optional failing step). Verify the end state on the live system *before* shipping. When a handed-over remedy fails, re-derive the model instead of offering the next theory-derived fix.

## Exploration guard rails

For open-ended tasks, explore briefly, then start writing code; partial progress beats perfect plans. Never spend a whole session on analysis without a working artifact.

One artifact does not buy unlimited exploration afterwards. After a few rounds with nothing further shipped, state the cumulative cost and what is left untested, and ask whether to continue.

**When the next step spends the user's time instead of yours, that check is due immediately.** The tell is a second consecutive round that ends by asking them to go and try something. Say what has been spent, what it ruled out and what the alternative costs, then let them choose; if the approach was wrong, lead with that.

**The same count applies when they are the only one who can see the result.** Tuning anything judged by eye (spacing, sizing, position) against a render you cannot open makes a change that did not take and one that looked wrong come back as the same report. After the second such round, get yourself a way to see it, or say plainly that you are guessing.
