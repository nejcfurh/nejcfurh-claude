# Orchestration

**When to apply:** deciding how to structure a multi-step task — one linear pass, a delegated subagent, a loop, or a fan-out Workflow graph.

## The primitives, by shape of work

- **Subagent (Agent tool)** — one deep delegate carrying its own context. Substantial single-domain work: a focused refactor, a specialist review. One head, sequential.
- **`/loop`, `/goal`** — the *same* task repeated over time or until a stop condition. Temporal, not parallel. See the Loops section in CLAUDE.md.
- **Workflow** — one *wide* fan-out within a turn: a fleet of subagents coordinated by a plain-JS script whose control flow costs zero model tokens. Nodes do the thinking; edges carry data between them.

Pick by shape, not size. Steps that each read the previous step's output are a line: keep them linear. Steps that don't are independent nodes, the only place a Workflow pays off. Litmus test: if you can't draw an arrow where a variable crosses from one step into the next, there is no dependency and the wait is wasted.

## Long-running local processes

Dev servers and other processes meant to outlive a turn should not be harness-tracked background tasks — those get reaped, and the reaper takes anything mid-flight with them. Launch them detached (`nohup … & disown`) so their lifetime is their own, or hand the user the command to run in their shell.

If one dies unexplained, diagnose before restarting it the same way. A clean shutdown in the log means it was signalled, not that it crashed — and processes dying in pairs points at an external sweep rather than the app. Restarting identically costs the user whatever was in flight a second time.

**A process you did not start is not yours to restart — find out whether you can before you stop it.** The restart is often not free: it may have been started under an environment, flag or working directory that no longer exists, and nothing about it while it is up tells you. If it refuses to come back, you have broken something that worked, mid-task. Establish the exact restart command and everything it needs first, and prefer the narrower fix — a stale cache or artifact can usually be invalidated without stopping anything. Say you are about to stop it, and if it will not restart, say so at once.

**Stop a named process, never a pattern.** `pkill -f` matched against a framework or runtime name catches every sibling using the same tooling — other projects, other ports, work nobody asked you to touch — and it reports the same success either way. Resolve the port to a pid first and signal that, then confirm what is still listening.

Before reporting a service down, check the **port**, not the process name: `lsof -nP -iTCP:<port> -sTCP:LISTEN`, or curl its status endpoint. Metro, Vite and friends run under `node` with argv that rarely holds the word you searched, so a `pgrep` miss reads as "not running" and misdirects the diagnosis. A listening port is not proof it is *your* app either: another project's dev server answers on the conventional port too. Confirm identity from the response — a title, a known route, a health payload — before testing against it.

## When a Workflow earns its cost

Reach for one only when the work is genuinely wide or needs structural confidence:

- **Breadth** — N independent items (files, routes, sources) each needing the same bounded job, more than one context can hold.
- **Gated verification** — findings worth confirming with independent skeptics before they reach the answer.
- **Unknown-size discovery** — a sweep that loops until K consecutive rounds surface nothing new.

Do **not** reach for one when the steps are a true dependency chain, a single agent handles it, "done" is a pure judgment call with no machine-checkable gate, or the task is trivial. A graph where every edge is an agent pays rent on its own plumbing — flatten/dedupe/filter is `results.flatMap(...)` and a `Set`, not an agent.

## Opt-in is mandatory

Never spin up a fleet unprompted — this is a cost gate, since one run can spawn dozens of agents. The Workflow tool description enumerates what counts as opt-in; the **Cost** rule and the **Loops** budget discipline in CLAUDE.md also apply in full: declare max agents up front, no scope expansion, escalate instead of retrying harder.

## Orchestrator sessions

**A new session in any repo or folder is the orchestrator for that work.** Every new ask runs in a nested session opened with `start_session`, never in the orchestrator itself, except a read-only check a handful of calls settle (a lookup, a first measurement of a reported symptom). Open it at once with `initiation: "user_asked"`: this rule is the user's standing request, so no "offer" card. Always pass `model` and `effort`; omitted, they inherit the orchestrator's Fable 5.2 at `medium`. `claude-opus-5-5` `high` for design-heavy or ambiguous asks, `medium` for a well-specified build; `claude-sonnet-5-5` `high` for mechanical or read-only ones. `start_session` takes nothing above the orchestrator's, so start a `high` tier at `medium`, then raise it via `set_session_effort` (may prompt). Writers use `use_worktree: true`. The orchestrator briefs, tracks, checks each result against its diff, and reports:

- **Progress**: one line per session, its link and state.
- **To do**: one short imperative line per item, the user's actions first. Nothing else.

**Rebuild both for each report from the owning system** (the forge's PR state, each session's latest report), never from the last report. The user drives children directly: a PR listed "to review" may have merged hours ago, and "do X before merging Y" outlives Y.

## Sibling sessions

**A claim is checked per step, not once per session.** Where several sessions share a plan, re-read the linked sessions and the shared notes folder before starting each step of it, and before fixing shared state such as a red base branch — assignments move between turns, and two sessions building the same piece only discover it at the PR. Starting a step, leave a one-line claim in the notes folder (step, branch, worktree); a claim found there means ask, not race.

**A sibling you cannot see races you too.** Before creating something meant to exist once per target on shared state — an experiment on a flag, a ticket, a scheduled reminder — list what exists for it. After the write, read it back and count: two means another session did the same; stop and ask which to keep.

## Node discipline

Topology mechanics (barriers, worktree isolation, output schemas, the verify and loop-until-dry patterns) live in the Workflow tool description; restating them here drifts. Only what it omits belongs below:

- **Every node gets a contract** — bounded input passed explicitly, never assumed from a shared window. A node that infers its scope from ambient context silently changes behavior when the caller changes.
- **Constrain nodes that read secrets or permissions** — a node auditing credential/permission config must reason *statically* from the file text. Never prompt it to probe real secret paths (`.vault-token`, `*.pem`, `~/.ssh`) or test whether a deny could be bypassed: that trips the credential-exploration security monitor even when the intent is a benign audit, and taints the run's output.
- **A constraint belongs on EVERY node that touches the finding** — finder, verifier, adjudicator, synthesiser. A verifier inherits a list of permission findings and will go probe them to "check" one, tripping the same monitor and tainting the same output; putting the static-only clause only on the finder buys nothing. Write the constraint once as a shared preamble string and interpolate it into every prompt, so a node cannot be added without it.
- **An audit node never runs the operation it audits** — a node reviewing a git gate reasons from the gate's source and its test suite; it does not fire `git commit` / `git push` / `rm` / `gh pr merge` to see what happens, throwaway repo or not. Executing the guarded operation is how a review run ends up publishing a branch or deleting files, and the gate's own suite already encodes the expected outcomes.
- **A delegate inherits your traps only if you write them down** — pass every failure mode you have already hit in that system, not just the latest. Warn about one trap and omit a second, and the delegate checks the first, then reports confidently through the second as verified. Where its output reaches the user directly — a scheduled run, a notification, a posted summary — also require it to corroborate every figure against a reference of independently known scale and name that reference: with no round trip to catch errors, the checks must be in the prompt.
- **A delegate that failed or stalled has usually already changed the tree.** A timeout, kill or error is not a rollback: its edits are applied and its verification is what did not happen — *unverified work that looks finished*, with nothing marking the half-done files. "The other agents succeeded" never makes a branch complete. For every delegate without a clean report, run its verification yourself and say which files you covered that way. Where several agents share a branch, re-run the whole gate afterwards: partial edits conflict only once both are in the tree.
- **A delegate must never adjust an assertion to match its own output.** Given a failing check, its cheapest move is editing the expectation, then reporting success in good faith — the test passes and the regression is pinned as correct. Say in the prompt that a check failing after its change is a finding to report, not a value to update, and that test expectations are out of scope unless you asked. When a report mentions changing an assertion, treat it as unreviewed: read the old and new expectation and decide which describes the behaviour you want — a plausible justification is what this mistake comes wrapped in.
- **Separate a delegate's measurements from its interpretations** — a report mixes counts and log lines it actually read with the causal story wrapped around them. The measurements are usually sound; the story often is not, since the delegate saw one slice and had every incentive to explain it. Verify the mechanism before repeating a causal claim in your own voice, above all somewhere durable: a PR description, a ticket, a closure note, a team message. "X is 404ing, so Y is broken" can be an accurate count welded to an invented cause, and the count makes the cause sound checked.
- **Tier by judgment, on two dials** — `model` sets the capability floor, `effort` how hard the node works at it. Mechanical nodes (extract, classify, reformat) get a cheap model *and* low effort; the synthesis/adjudication node gets the strong model at high or above. Pull the model dial first: a frontier model at low effort where `haiku` would pass looks like cost discipline and leaves most of the bill in place. Phase routing (below) decides which model counts as "the strong one".

## Model and effort routing

**Plan on Fable 5.2, code on Opus 5.5; nested sessions use the tiers above.** Planning is understand / spec / grill / design / review-the-approach. Coding is implement / fix / verify. The boundary is the moment a plan is agreed, not the first file edit.

- **Subagents** — pass `model` on the Agent call, nested sessions included: `'fable'` for planning delegates (`Plan`, `product-manager`, spec and architecture review), `'opus'` for delegates that write code. Definitions in `agents/` carry no `model:` frontmatter: routing is per-call, since one specialist plans in one turn and implements in the next.
- **Workflow nodes** — same split via `opts.model`. Cheap extract/classify nodes still go to `haiku` in any phase.
- **Main session** — only the user's `/model` changes the session model (`settings.json` is write-blocked and would not apply mid-session). Outside an orchestrator, which never implements, state the switch once where the user is already answering — plan approval, spec sign-off: "Plan's agreed — `/model` to Opus 5.5 before I build."

The subagent/node `model` enum is `fable | opus | sonnet | haiku`: a tier, not a context variant. A 1M-context variant is a `/model` choice; through `start_session` it is untested.

**Per call, effort is a narrower surface than model.** `opts.effort` (`low | medium | high | xhigh | max`) exists on Workflow nodes; omit it to inherit the session effort. The **Agent tool has no `effort` parameter** — writing one into an Agent call does nothing, so a subagent that should be cheap gets a cheaper `model` instead. A subagent or skill *definition* can pin `effort:` in its frontmatter, but that fixes it for every call, which is why the definitions in `agents/` leave it out, as they leave out `model:`. Session effort is the user's to set, same as session model.

## Saved workflows

A good run can be saved for reuse and watched live with `/workflows`. Built-in workflows and scripts in `.claude/workflows/` or `~/.claude/workflows/` resolve by name (`/<name>`); `scriptPath` launches any script by path. A workflow scoped to one repo lives in that repo's `.claude/workflows/`. Running a saved workflow still requires opt-in. Worked example: `.claude/workflows/config-consistency-audit.js` (fan out over subsystems → verify each finding → synthesize a ranked report).

Don't document a launch or discovery mechanism as working until you've run it once: name resolution, flags and auto-discovery vary by harness version, and a failed launch describes that version only. State the verified behavior, not the plausible one.
