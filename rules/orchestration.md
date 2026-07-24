# Orchestration

**When to apply:** deciding how to structure a multi-step task — one linear pass, a delegated subagent, a loop, or a fan-out Workflow graph.

## The primitives, by shape of work

- **Subagent (Agent tool)** — one deep delegate carrying its own context. Substantial single-domain work: a focused refactor, a specialist review. One head, sequential.
- **`/loop`, `/goal`** — the *same* task repeated over time or until a stop condition. Temporal, not parallel. See the Loops section in CLAUDE.md.
- **Workflow** — one *wide* fan-out within a turn: a fleet of subagents coordinated by a plain-JS script whose control flow costs zero model tokens. Nodes do the thinking; edges carry data between them.

Pick by shape, not size. Steps that each read the previous step's output are a line — keep them linear. Steps that don't consume each other's output are independent nodes — that is the only place a Workflow pays off. Litmus test: if you can't draw an arrow where a variable crosses from one step into the next, there is no dependency and the wait is wasted.

## When a Workflow earns its cost

Reach for one only when the work is genuinely wide or needs structural confidence:

- **Breadth** — N independent items (files, routes, sources) each needing the same bounded job, more than one context can hold.
- **Gated verification** — findings worth confirming with independent skeptics before they reach the answer.
- **Unknown-size discovery** — a sweep that loops until K consecutive rounds surface nothing new.

Do **not** reach for one when the steps are a true dependency chain, a single agent handles it, "done" is a pure judgment call with no machine-checkable gate, or the task is trivial. A graph where every edge is an agent pays rent on its own plumbing — flatten/dedupe/filter is `results.flatMap(...)` and a `Set`, not an agent. Spend agents on judgment, not wiring.

## Opt-in is mandatory

Never spin up a fleet unprompted. A Workflow runs only on explicit opt-in — the keyword `ultracode`, a direct ask ("use a workflow", "fan out agents"), or a skill that invokes it. Otherwise use a subagent, or describe the workflow and its rough token cost and ask first. This is a cost gate: one run can spawn dozens of agents. The **Cost** rule and the **Loops** budget discipline in CLAUDE.md apply in full — declare max agents up front, no scope expansion, and escalate instead of retrying harder.

## Topology defaults (once building one)

- **`pipeline()` by default; a barrier (`parallel()` between stages) only when a stage needs every prior result at once** — cross-set dedupe, early-exit on the total, a prompt that compares against "the other findings". "Cleaner code" and "the stages feel separate" are not reasons; barrier latency is real, measurable, wasted time.
- **Every node gets a contract** — bounded input passed explicitly (never assumed from a shared window), schema-validated output so the next node consumes it without guessing.
- **Verify before trusting** — put a skeptic on the edge for any finding that will drive a decision; give diverse verifiers distinct lenses (correctness, security, does-it-reproduce) rather than N identical ones.
- **Converge every cycle** — loop-until-dry must dedupe against *everything seen*, not just confirmed results, or rejected findings reappear forever.
- **`isolation: 'worktree'` only when nodes write files in parallel** — a seatbelt for that one topology, not a default tax.
- **Tier models** — route repetitive extract/classify nodes to a cheaper model; keep the synthesis/adjudication node on the strong one. Omit the override when unsure — nodes inherit the session model.

## Saved workflows

A good run can be saved for reuse — version-controlled and viewable live with `/workflows`. Built-in workflows resolve by name; a project-local script in `.claude/workflows/` is launched by its **path** (`scriptPath`), not by name in this harness. Global orchestration guidance lives here; a workflow scoped to a single repo lives in that repo's `.claude/workflows/`. Running any saved workflow still requires opt-in. Worked example: `.claude/workflows/config-consistency-audit.js` (fan out over subsystems → verify each finding → synthesize a ranked report).
