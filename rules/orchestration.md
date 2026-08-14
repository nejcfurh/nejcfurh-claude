# Orchestration

**When to apply:** deciding how to structure a multi-step task — one linear pass, a delegated subagent, a loop, or a fan-out Workflow graph.

## The primitives, by shape of work

- **Subagent (Agent tool)** — one deep delegate carrying its own context. Substantial single-domain work: a focused refactor, a specialist review. One head, sequential.
- **`/loop`, `/goal`** — the *same* task repeated over time or until a stop condition. Temporal, not parallel. See the Loops section in CLAUDE.md.
- **Workflow** — one *wide* fan-out within a turn: a fleet of subagents coordinated by a plain-JS script whose control flow costs zero model tokens. Nodes do the thinking; edges carry data between them.

Pick by shape, not size. Steps that each read the previous step's output are a line — keep them linear. Steps that don't consume each other's output are independent nodes — that is the only place a Workflow pays off. Litmus test: if you can't draw an arrow where a variable crosses from one step into the next, there is no dependency and the wait is wasted.

## Long-running local processes

Dev servers and other processes meant to outlive a turn should not be harness-tracked background tasks — those get reaped, and the reaper takes anything mid-flight with them (an interrupted GPU job, a half-written build). Launch them detached (`nohup … & disown`) so their lifetime is their own, or hand the user the command to run in their shell.

If one dies unexplained, diagnose before restarting it the same way. A clean shutdown in the log means it was signalled, not that it crashed — and processes dying in pairs points at an external sweep rather than the app. Restarting identically costs the user whatever was in flight a second time.

Before reporting a service down, check the **port**, not the process name: `lsof -nP -iTCP:<port> -sTCP:LISTEN`, or curl its status endpoint. A `pgrep` for a plausible-looking name is a guess — Metro, Vite and friends run under `node` with argv that rarely contains the word you searched for, so a name miss reads as "not running" and sends the diagnosis down the wrong path entirely.

## When a Workflow earns its cost

Reach for one only when the work is genuinely wide or needs structural confidence:

- **Breadth** — N independent items (files, routes, sources) each needing the same bounded job, more than one context can hold.
- **Gated verification** — findings worth confirming with independent skeptics before they reach the answer.
- **Unknown-size discovery** — a sweep that loops until K consecutive rounds surface nothing new.

Do **not** reach for one when the steps are a true dependency chain, a single agent handles it, "done" is a pure judgment call with no machine-checkable gate, or the task is trivial. A graph where every edge is an agent pays rent on its own plumbing — flatten/dedupe/filter is `results.flatMap(...)` and a `Set`, not an agent. Spend agents on judgment, not wiring.

## Opt-in is mandatory

Never spin up a fleet unprompted — this is a cost gate, since one run can spawn dozens of agents. The Workflow tool description enumerates what counts as opt-in; what it does not say is that the **Cost** rule and the **Loops** budget discipline in CLAUDE.md apply in full: declare max agents up front, no scope expansion, escalate instead of retrying harder.

## Node discipline

Topology mechanics — barriers, worktree isolation, output schemas, the verify and loop-until-dry patterns — live in the Workflow tool description, which loads only when the tool is in play. Restating them here costs tokens every session and drifts. Only what the tool description omits belongs below:

- **Every node gets a contract** — bounded input passed explicitly, never assumed from a shared window. A node that infers its scope from ambient context silently changes behavior when the caller changes.
- **Constrain nodes that read secrets or permissions** — a node auditing credential/permission config must reason *statically* from the file text. Never prompt it to probe real secret paths (`.vault-token`, `*.pem`, `~/.ssh`) or test whether a deny could be bypassed: that trips the credential-exploration security monitor even when the intent is a benign audit, and taints the run's output.
- **A constraint belongs on EVERY node that touches the finding** — finder, verifier, adjudicator, synthesiser. A verifier inherits a list of permission findings and will go probe them to "check" one, tripping the same monitor and tainting the same output; putting the static-only clause only on the finder buys nothing. Write the constraint once as a shared preamble string and interpolate it into every prompt, so a node cannot be added without it.
- **An audit node never runs the operation it audits** — a node reviewing a git gate reasons from the gate's source and its test suite; it does not fire `git commit` / `git push` / `rm` / `gh pr merge` to see what happens, throwaway repo or not. Executing the guarded operation is how a review run ends up publishing a branch or deleting files, and the gate's own suite already encodes the expected outcomes.
- **A delegate inherits your traps only if you write them down** — pass every failure mode you have already hit in that system, not just the most recent one. A prompt that warns about one trap and omits a second teaches the delegate to check the first and then report confidently through the second; worse, having "verified" the thing you named, it presents the result as sound. Where its output reaches the user directly — a scheduled run, a notification, a posted summary — also require it to corroborate every figure against a reference whose scale is known independently, and to state which reference it used. A delegate that cannot be corrected before its output lands needs the checks written into the prompt, because there is no round trip in which to catch it.
- **Separate a delegate's measurements from its interpretations** — a subagent report mixes counts and log lines it actually read with the causal story it wrapped around them. The measurements are usually sound; the story often is not, because the delegate saw one slice and had every incentive to explain it. Verify the mechanism yourself before repeating a causal claim in your own voice, and above all before it lands somewhere durable like a PR description, a ticket or a message to a team. "X is 404ing, so Y is broken" can be an accurate count welded to an invented cause — and the count is what makes the cause sound checked.
- **Tier by judgment, on two dials** — `model` sets the capability floor, `effort` sets how hard the node works at it. Mechanical nodes (extract, classify, reformat) get a cheap model *and* low effort; the synthesis/adjudication node gets the strong model at high or above. Pull the model dial first: dropping a frontier model to low effort where `haiku` would have passed is the smaller lever, and it reads as cost discipline while leaving most of the bill in place. Phase routing (below) decides which model counts as "the strong one".

## Model and effort routing

**Planning runs on Fable 5. Coding runs on Opus 5 (1M context).** Planning is understand / spec / grill / design / review-the-approach. Coding is implement / fix / verify. The boundary is the moment a plan is agreed, not the first file edit.

- **Subagents** — pass `model` on the Agent call: `'fable'` for planning delegates (`Plan`, `product-manager`, spec and architecture review), `'opus'` for delegates that write code. Definitions in `agents/` deliberately carry no `model:` frontmatter — routing is per-call, chosen by the phase in play, because the same specialist plans in one turn and implements in the next.
- **Workflow nodes** — same split via `opts.model`. A cheap extract/classify node still goes to `haiku` regardless of phase; phase routing governs the thinking nodes, not the wiring ones.
- **Main session** — the session model cannot be changed from inside a turn; only the user's `/model` can (`settings.json` is write-blocked and wouldn't apply mid-session either). So state the switch in one line at the boundary, and pick a boundary where the user is already answering — plan approval, spec sign-off — so it costs no extra turn: "Plan's agreed — `/model` to Opus 5 (1M) before I build." Say it once and continue; don't stall the task on it.

The subagent/node `model` enum is `fable | opus | sonnet | haiku` — a tier, not a context variant. There is no `opus[1m]` value to pass; the 1M-context choice exists only at session level.

**Effort is a narrower surface than model.** `opts.effort` (`low | medium | high | xhigh | max`) exists on **Workflow nodes only**; omit it to inherit the session effort. The **Agent tool has no `effort` parameter** — writing one into an Agent call does nothing, so a subagent that should be cheap gets a cheaper `model` instead. Session effort is the user's to set, same as session model. Treat any advice that routes effort per-subagent, or that describes effort as a prompt-cache key, as describing a different harness than this one until verified here.

## Saved workflows

A good run can be saved for reuse — version-controlled and viewable live with `/workflows`. Built-in workflows resolve by name; a project-local script in `.claude/workflows/` is launched by its **path** (`scriptPath`), not by name in this harness. Global orchestration guidance lives here; a workflow scoped to a single repo lives in that repo's `.claude/workflows/`. Running any saved workflow still requires opt-in. Worked example: `.claude/workflows/config-consistency-audit.js` (fan out over subsystems → verify each finding → synthesize a ranked report).

Don't document a launch or discovery mechanism as working until you've run it once. Name resolution, flags, and auto-discovery vary by harness version — the by-name-vs-by-path split above was learned by a failed launch, not read from docs. State the verified behavior; don't promise the plausible one.
