---
name: retro
description: Grade the session's trajectory, not just its outcome, and encode what went wrong into the config so it can't recur. Invoke after a correction, a session that went sideways, or when the user says "retro", "what went wrong", or "make sure this doesn't happen again". `/retro gates` reads the gate-block history instead — which gates fire most and which never do.
---

Run a retrospective on: $ARGUMENTS (default: this session's work)

The outcome may even be fine — the question is whether the *path* was right, and what the config should learn from it.

## 1. Reconstruct the trajectory

List what actually happened, in order: the task as stated, the assumptions made, files read and touched, commands run, gates that fired (or should have), corrections the user had to make. Facts only — no defense of decisions.

## 2. Grade the trajectory

For each misstep, classify it:

- **Wrong assumption** — acted on stale or guessed context instead of checking (didn't read the file, trusted conversation memory over `git status`).
- **Scope drift** — touched things the task didn't ask for.
- **Missed gate** — a hook/check existed but was bypassed, or the failure class has no gate at all.
- **Rule gap** — no rule covers this; the mistake was reasonable given the config.
- **Rule ignored** — a rule covers this and wasn't followed; the rule may be buried, ambiguous, or contradicted elsewhere.

## 3. Encode the fix (the point of the exercise)

For each finding, propose the *cheapest durable fix*, preferring mechanical over attentional:

1. **Hook** — if it's pattern-checkable at tool-call time, it becomes a gate, not advice.
2. **Rule edit** — if it's a judgment call, add or sharpen a line in `rules/` or CLAUDE.md; update the existing rule rather than adding a duplicate.
3. **Skill edit** — if a workflow step was skipped or misordered, fix the skill that owns that workflow.
4. **Memory** — if it's a fact about this user/project rather than a rule, save it to memory.
5. **No fix** — genuinely one-off; say so and don't add config noise. A rule nobody needed twice is bloat.

## 4. Apply

Present the findings and proposed fixes as a short table (misstep → class → fix → where). On approval, make the edits in the config repo and commit. One retro finding that becomes a hook is worth ten that become paragraphs.

### Write it so it cannot leak

The config repo is shared, outlives any single engagement, and may be public. Everything a retro puts there — rule text, commit message, PR title and body, branch name — must read as generic craft guidance and carry nothing identifying where the lesson came from.

Never write: client, company or product names; ticket identifiers or their prefixes; internal repo, service, environment, table or flag names; links to internal tools; verbatim internal conventions or guidelines; file paths that exist only in that codebase.

Generalize instead — "a client project", "a ticket", "an internal ticket-prefix convention", "a project-specific env file". A finding that needs the original repo named to make sense is not yet a rule.

**Never encode one project's convention into a global rule, gate or hook.** If it only makes sense for one codebase it belongs in that project's own config. Split every finding: the generalized lesson goes to the config repo, the specifics and evidence go to memory, which is per-project and private.

Before committing, pre-flight with the gate's own matcher, never a hand-written grep: source `hooks/leak-patterns-lib.sh` and run `leak_scan --repo "$(git rev-parse --show-toplevel)"` over the commit message, any PR body, and the **added** lines only (`git diff --cached | grep '^+' | grep -v '^+++'`). It reports the matched *class* and never the text, and it needs no protected name typed anywhere.

**Read what it prints, never its exit status.** `leak_scan` reports a match by printing the class names and exits 0 whether or not it found one, so `leak_scan … && echo clean` says clean for every input. Capture the output (`o=$(… | leak_scan --repo "$R")`) and treat anything non-empty as a leak. Before trusting a clean result, feed it a made-up ticket key once and confirm it prints `ticket-key`.

Writing your own grep is the trap, and it fails three ways at once. The pattern has to spell out the very names being protected, so it discloses them into the command line and the transcript. The commit gate scans command prose as well as content, so it then blocks the commit *because of the check* — and the block names a class, not a location, so the obvious reading is that the content is dirty when it is the command that is. And a grep over the full `git diff --cached` inspects text the gate never reads, since the gate deliberately ignores deletions and context so that removing an identifier is not punished; a mismatch there invents a defect in the gate that does not exist. Scan exactly what the gate scans, with the function the gate uses.

The rule text is usually already clean — the commit message and PR body are where it leaks.

## 5. Gate history (`/retro gates`)

A session retro sees one session's blocks. This pass reads every block since the history began, from `~/.claude/state/gate-block-history.tsv` (one `date<TAB>gate` line per block, written by `record-gate-block.sh` and never pruned). Run it with the argument `gates`; it is worth running about once a week.

1. **Tally.** All time, and the last 30 days:

   ```bash
   h="$HOME/.claude/state/gate-block-history.tsv"
   head -1 "$h" | cut -f1
   cut -f2 "$h" | sort | uniq -c | sort -rn
   since=$(date -v-30d +%F 2>/dev/null || date -d '30 days ago' +%F)
   awk -F'\t' -v d="$since" '$1 >= d { print $2 }' "$h" | sort | uniq -c | sort -rn
   ```

   The first line is the date the history starts. A history a few weeks long cannot show that a gate never fires.
2. **List what can appear.** `grep -l record-gate-block.sh hooks/pre-*gate.sh` in this repo gives the gates that record. A hook missing from that list shows zero because it never writes, not because it never fires — say which ones those are.
3. **Read it.**
   - **A gate near the top** blocks the same mistake again and again. Fix the producer — the skill, rule or habit that emits the blocked command — not the gate. The gate is working.
   - **A recording gate with zero blocks** over a long history is a candidate to retire, never a deletion: it may be a deterrent that works, or its failure class may be gone. Report it with the history's start date and let the user decide.
4. **Report** a table — gate | last 30 days | all time | reading — then encode any fix through §3 and §4.
