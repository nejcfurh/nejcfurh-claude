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
- **Tier models** — route repetitive extract/classify nodes to a cheaper model; keep the synthesis/adjudication node on the strong one. Phase routing (below) decides which model counts as "the strong one".

## Model routing by phase

**Planning runs on Fable 5. Coding runs on Opus 5 (1M context).** Planning is understand / spec / grill / design / review-the-approach. Coding is implement / fix / verify. The boundary is the moment a plan is agreed, not the first file edit.

- **Subagents** — pass `model` on the Agent call: `'fable'` for planning delegates (`Plan`, `product-manager`, spec and architecture review), `'opus'` for delegates that write code. Definitions in `agents/` deliberately carry no `model:` frontmatter — routing is per-call, chosen by the phase in play, because the same specialist plans in one turn and implements in the next.
- **Workflow nodes** — same split via `opts.model`. A cheap extract/classify node still goes to `haiku` regardless of phase; phase routing governs the thinking nodes, not the wiring ones.
- **Main session** — the session model cannot be changed from inside a turn; only the user's `/model` can (`settings.json` is write-blocked and wouldn't apply mid-session either). So state the switch in one line at the boundary, and pick a boundary where the user is already answering — plan approval, spec sign-off — so it costs no extra turn: "Plan's agreed — `/model` to Opus 5 (1M) before I build." Say it once and continue; don't stall the task on it.

The subagent/node `model` enum is `fable | opus | sonnet | haiku` — a tier, not a context variant. There is no `opus[1m]` value to pass; the 1M-context choice exists only at session level.

## Saved workflows

A good run can be saved for reuse — version-controlled and viewable live with `/workflows`. Built-in workflows resolve by name; a project-local script in `.claude/workflows/` is launched by its **path** (`scriptPath`), not by name in this harness. Global orchestration guidance lives here; a workflow scoped to a single repo lives in that repo's `.claude/workflows/`. Running any saved workflow still requires opt-in. Worked example: `.claude/workflows/config-consistency-audit.js` (fan out over subsystems → verify each finding → synthesize a ranked report).

Don't document a launch or discovery mechanism as working until you've run it once. Name resolution, flags, and auto-discovery vary by harness version — the by-name-vs-by-path split above was learned by a failed launch, not read from docs. State the verified behavior; don't promise the plausible one.
