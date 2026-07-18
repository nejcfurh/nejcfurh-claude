---
name: review-pr
description: Structured pull-request review with severity-classified findings. Invoke when the user says "review this PR", "code review", or provides a PR number or GitHub PR URL.
---

Review PR: $ARGUMENTS

## 1. Fetch the PR

Use `gh`: `gh pr view <ref> --comments` for description and discussion, `gh pr diff <ref>` for the diff. Note the stated intent — you'll judge the diff against it.

If the PR links a ticket or issue, read it and judge the diff against its **requirements** — they are the source of truth for the objective. The ticket's proposed solution is only a suggestion; don't penalize the PR for taking a different but valid approach.

## 2. Read beyond the diff

Diff hunks alone can't establish correctness. Read enough surrounding code to judge each change in context: the full function/module being modified, callers of changed signatures, related tests. Check out the branch locally if that's easier.

## 3. Review against the checklist

Work through `./checklist.md` (in this skill's directory) dimension by dimension.

## 4. Classify every finding

Each finding gets a severity, a `file:line` reference, and a concrete rationale (why it's a problem, ideally with the fix):

- **BLOCKER** — must fix before merge: bugs, security holes, data loss, broken behavior.
- **ISSUE** — should fix: real problems that won't corrupt anything today.
- **SUGGESTION** — consider: better approaches, worthwhile simplifications.
- **NIT** — style and polish; never blocks.
- **PRAISE** — call out genuinely good work; reviews aren't only for faults.

No vague findings — "this looks fragile" is not a finding; "file.ts:42 — `items[0]` throws on empty array; guard or use `.at(0)`" is.

Ask of every change: **what must already be true outside this diff for this to be safe in production?** A migration or backfill that must run first, deploy ordering, a feature flag, an env var, a session refresh. If verifiable from the diff (e.g. whether the migration file is actually included), verify it there and report the result. If not, and the PR doesn't establish the precondition, that's a finding — state exactly what a human must verify before merge.

## 5. Specialist passes

For diffs heavy in a specialist domain, offer to spawn the matching subagent: `frontend-staff-engineer` (React/RN/Next.js UI), `backend-staff-engineer` (API/services), `cybersecurity-expert` (auth, input handling, crypto), `database-master` (schema, migrations, queries). Merge their findings into your severity buckets.

## 6. Re-reviews

If a prior review of this PR exists (yours or another reviewer's), treat its BLOCKER/ISSUE findings as a checklist and reconcile each against the current state:

- **Fixed** — correctly addressed. Confirm it; don't re-list it as a finding.
- **Still open** — persists or only partially addressed. Re-flag at its original severity.
- **Accepted** — a human explicitly acknowledged the risk in a reply. Don't re-flag it.
- **No longer applicable** — the code or requirement changed. Note it briefly.

Then surface anything new since the last review with the same strictness. Suggestions and nits are not carried forward as a checklist.

## 7. Verdict

End with:

- **Verdict: APPROVE** (no blockers, issues acceptable or absent) or **Verdict: REQUEST CHANGES** (any blocker, or issues that must be addressed).
- All findings grouped by severity, blockers first.
