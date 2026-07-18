---
name: address-pr-comment
description: Address the review feedback on a PR — automated review bots AND human reviewer comments — then commit and push the fixes. Invoke when asked to address, handle, or resolve the review comments on a PR. Input is a PR number or URL (defaults to the PR for the current branch).
---

# Address PR Review Comments

Address the review feedback on a pull request — automated review comments and
human reviewer comments — then push the fixes. **Input:** a PR number or URL; if
omitted, use the PR for the current branch.

## Step 1 — Identify the PR

Extract the PR number (bare number or `.../pull/<number>`), or resolve it from
the current branch. Capture the branch and repo — you need both later:

```bash
PR=<number>                                              # or: $(gh pr view --json number --jq .number)
BRANCH=$(gh pr view "$PR" --json headRefName --jq .headRefName)
REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner)
```

If there is no PR for the branch and none was passed, stop and ask.

## Step 2 — Get onto the PR branch safely

If the repo has its own worktree helper script (check `scripts/` and CLAUDE.md),
use it — reuse an existing worktree for the branch if one exists. Otherwise
check out the branch directly (or `git worktree add` if the main checkout is
busy). Then sync:

```bash
git fetch origin "$BRANCH" --quiet
git status --short                       # check for pre-existing local changes
```

- If the checkout is **clean**, sync to the pushed PR state: `git reset --hard origin/$BRANCH`.
- If it has **unrelated uncommitted changes**, do NOT discard them — stop and ask.

## Step 3 — Wait for the automated review, if the repo has one

Some repos run an automated PR review (a bot comment, often carrying a marker
line — check CLAUDE.md or past PRs for the signature). Right after a PR opens
that review may not exist yet. If one is expected, poll (bounded) for it:

```bash
MARKER="<the repo's bot-review signature, or the bot's login>"
for i in $(seq 1 40); do
  n=$(gh pr view "$PR" --json comments \
        --jq "[.comments[]|select(.body|contains(\"$MARKER\"))]|length")
  [ "$n" -ge 1 ] && { echo "REVIEW_POSTED after ~$((i*90))s"; break; }
  sleep 90
done
```

If the repo has no automated review, or the loop exhausts, continue — there may
still be human feedback to address. (Human comments arrive on their own
schedule — don't wait on them; address whatever is present now, and re-run later
to pick up new ones.)

## Step 4 — Gather ALL feedback (bot + human) and check CI

Collect every actionable signal, then dedupe:

```bash
# Conversation comments (bot reviews usually land here).
gh pr view "$PR" --json comments --jq '.comments[] | {author:.author.login, body}'
# Reviews (state = APPROVED / CHANGES_REQUESTED / COMMENTED) + their summary bodies.
gh pr view "$PR" --json reviews  --jq '.reviews[]  | {author:.author.login, state, body}'
# Inline code comments (file + line).
gh api "repos/$REPO/pulls/$PR/comments" \
  --jq '.[] | {author:.user.login, path:.path, line:.line, body:.body}'
```

- **Bot findings:** the most recent automated review comment. If it reports no
  blocking issues, there's nothing from the bot — but still handle human
  comments + CI.
- **Human findings:** reviews marked `CHANGES_REQUESTED` and inline comments
  that request a change. A human **question or discussion** is not a code
  change — don't silently "fix" it (see step 5).
- **CI (independent of any review):**
  `gh pr view "$PR" --json statusCheckRollup --jq '.statusCheckRollup[]|{name,conclusion}'`.
  A clean review does **not** mean green CI. If checks show `FAILURE`, get the
  failing output (run the tests locally, or `gh run view <run-id> --log-failed`)
  and fix them **in scope** — usually a stale mock/assertion from this change.
  Don't weaken assertions or change prod behavior to mask a real regression. A
  failure that also fails on the base branch is pre-existing — note it as
  skipped, don't fix it here.

If there is nothing actionable (no bot findings, no human change requests,
green CI), report that and stop.

## Step 5 — Address the findings

Bot findings in severity order (blockers first), then human change requests:

- If the fix is **clear and correct**, make it.
- If a finding (bot or human) is a **judgment call** — accepting a risk,
  choosing between approaches, anything touching prod state/behavior — **ask
  the user** before acting; don't guess. A finding the user accepts is
  **skipped**, not fixed.
- If a finding is **wrong** or out of scope, don't "fix" it — note it and skip it.
- A human **question / discussion comment** that asks for no change: surface it
  to the user (so they can reply) rather than inventing a code change for it.
- Stay strictly in scope for this PR. Honor the project's CLAUDE.md rules
  (logging conventions, comment policy, commit-message format, hooks that
  already run lint/format).

## Step 6 — Verify

Re-run the relevant/failing tests and the project's check commands (detect from
package scripts, CI config, or CLAUDE.md — never assume the package manager).
Run integration/build only if you touched code that warrants it.

## Step 7 — Commit + push + report

**One** commit to the same remote branch, following the repo's commit-message
conventions (ticket prefix if the branch carries one) and naming what it
addresses (bot findings, human requests, CI fixes):

```bash
git add -A
git commit -m "<prefix>: address review — <e.g. fix X (bot), guard Y (reviewer @name)>"
git push
```

Then report per finding — **fixed / skipped (why)**, split into **bot** vs
**human reviewer** — whether failing CI checks were fixed, any human questions
left for the user to answer, and the commit SHA.
