# Git Conventions

**When to apply:** every commit, branch operation, or pull-request action.

## Commits

- Conventional commits format (`feat:`, `fix:`, `refactor:`, `docs:`, `chore:`, `test:`, `ci:`). Scope optional: `feat(auth): add token refresh`. (Enforced by hook.)
- Immediately before committing, review `git diff --cached --stat` — the index may hold earlier staged changes (a stray `git rm`, a forgotten `add`). Commit exactly what the message describes.
- **Never add Co-Authored-By or any AI attribution** — commits, PR titles/descriptions, issues, comments, including the "Generated with Claude Code" footer harnesses append by default. (Enforced by hook.)
- Never commit directly to `main`/`master` — verify the branch first, use a feature branch. (Enforced by hook.)
- Autonomous commit, push, and PR creation are allowed by default. Before pushing: feature branch, `/verify-done`, gates pass. Still **never** auto-merge (the user merges) and never push to the default branch; force pushes to feature branches need no asking. A project can re-require explicit instructions in its own CLAUDE.md.
- **Handing the user a push command is the fallback for a gate you cannot pass right now, never a standing arrangement.** A handoff saying "the user pushes" records that moment's blocker, not a rule (*a fence with a date on it*, `engineering-principles.md`). Run `/verify-done`; on READY, push yourself. Only an unfixable failing check, or the user saying so this session, makes the push theirs — say which.
- **Never route around a gate.** When a hook blocks a git operation, do not re-issue it through wrappers or alternate command forms. Fix the trigger (feature branch, ff-merge) or hand the exact command over for the `!` prefix. A commit made by a tool other than `git commit` is an alternate form: `gh stack init|add -A -m …` commits with no `commit` on the line, so the gates sit it out. Stage and commit separately. (Gated.)

## Branches and PRs

- Never push to the default branch — feature branch + PR, always. (Enforced by hook.)
- Force pushes to feature branches are allowed without asking, bare `--force` included; prefer `--force-with-lease` when the remote may have moved. Never force-push the default or a protected branch (hook + deny rules).
- To undo commits, use `git reset --soft` (keeps changes staged). Never `git reset --hard` — it is deny-blocked; if a hard discard is truly needed, ask the user to run it.
- Never merge PRs — the user merges manually. (Enforced by hook.)
- Never close/reopen a PR (or otherwise manipulate PR open/closed state) to work around tooling — it notifies reviewers and re-triggers CI. A stale result clears on the next push or an explicit re-run; otherwise ask.
- One PR = one concern. Once a PR is open, a new request gets a new branch off main — add commits to an open PR only when the user says so, since it can merge at any moment. Work that genuinely *depends* on the open PR gets stacked (below). A fix needed only to get a check green — a flaky or racing test, a stale fixture elsewhere in the repo — is a separate concern too, even when the instruction is "make it pass": name it, and ask before it lands in the PR.
- When branching off a protected base (`develop`/`main`) — including via `git worktree add -b <branch> <path> origin/<base>` — don't leave the branch tracking it: `git branch --unset-upstream`, or create it with `--no-track`. This is about tracking the *base*: once the branch is pushed, tracking its own `origin/<branch>` is correct — never unset that.
- Rebase onto the target branch (`git fetch origin main && git rebase origin/main`) before creating a PR.
- **Resolve a conflict by reading the region and choosing, never by pattern-matching across the markers.** The two sides are near-identical by construction, so a scripted marker-strip takes the wrong brace, tag or clause silently. Before `git rebase --continue`, confirm the file parses and delimiters balance; otherwise the break surfaces later in a suite that points nowhere near the rebase.
- Run `/verify-done` before pushing any branch. (Enforced by hook — READY records a marker pushes require; any edit invalidates it. Only a clean tracked tree gets push-ready READY; a dirty one gets READY TO COMMIT.)
- **Decide the destination of every working-tree change before starting a commit flow.** Push-ready READY needs a clean tree, so something deliberately left uncommitted dead-ends at the gate. Raise it — commit, drop, or hand over the push — when the user asks to commit.
- PR descriptions: bullet points in the summary, not prose paragraphs.
- After pushing new commits to an existing PR, update its title and description (`gh pr edit`) to reflect all changes.
- If the repo has a PR template, use it.

## Stacking

A stack keeps dependent concerns separately reviewable; it is what lets "one PR = one concern" survive dependent work. Default to one when any of these holds:

- the work runs past ~30 files or ~1000 lines
- new work depends on a PR that is already open
- a branch has grown into concerns a reviewer would want to judge one at a time

Reviewability is the thing being optimised: two PRs that each read in one sitting beat one nobody finishes.

**Mechanics.** `gh stack` (`gh extension install github/gh-stack`) owns branch topology; `git add` + `git commit` own content. Never `gh stack init|add -A -m` — it commits behind the gates.

**Slicing.**

- **Order bottom-up, trunk first:** dependencies and config → schema and migrations → data access → API and business logic → UI → tests and docs that belong to no slice above.
- **The seam test.** Every slice builds and passes on its own, referencing nothing above it; slices that cannot both pass are one slice. A stack with a non-compiling middle PR is worse than one large PR.
- **No ordinals in branch names.** Position lives in each PR's base; a `-1-`/`-2-` prefix goes stale on the first reorder. Share a stem across the slice names.
- **Each PR body covers only its own slice**, and states its position and what it sits on.
- **Slicing an existing branch is restructuring.** Propose the slice plan and get approval before mutating anything, take a backup ref first, and name it.
- **How it merges depends on whether the host knows it is a stack.** A *registered* stack merges atomically — merging the top PR lands every unmerged PR below it and rebases the next one onto trunk. A chain merely based on each other merges bottom-up, one at a time. Check the API field before planning the merge.
- **A registered stack keeps itself rebased — never rebase one by hand.** Whenever its base moves (any merge to trunk, including someone merging a PR out of the stack), the host rebases every PR onto the new base and force-pushes them, committer shown as the host. A manual restack races that: `--force-with-lease` refuses your push, but the rebase and its gate run are already spent. Before any stack mutation, fetch immediately; to sync, compare each PR's diff to its own previous tip (patch ids), then reset the local branches to the remote tips.
- **Read the allowed merge methods off the base branch's ruleset, not the repo settings.** The ruleset can narrow them to one. Squash is fragile on a stack (it replaces the commits upper branches sit on); confirm it is permitted and supported first.

## State freshness

State from earlier in the conversation goes stale — and so do local clones.

- **External state a handoff hands you is unverified, not established.** A handoff saying a flag, dashboard, queue or record does not exist is a claim about a system others change. Re-read it from the owning system before repeating it, planning around it, or writing it down.
- **Repos:** before analyzing, comparing, or building on any repo — at task start and after any gap — run `git fetch` and `git status -sb`.
- **Your own config checkout counts too.** A session-start notice that the config repo is behind or could not sync means this session's hooks and rules are older than upstream. Relay it in the first reply, with the command that pulls it.
- **A three-dot diff is the sharp edge of that, and it fails as an accusation.** `git diff <base>...HEAD` takes its merge-base from the remote-tracking ref, so a stale `origin/<base>` presents other people's landed commits as work on this branch. Fetch the base right before reading one; for "what is in this change", prefer the forge API and reconcile before saying who put a commit where. A `fetch-age` warning on the `[pr-state]` line makes every ahead/behind count suspect.
- **Pick the diff form from the question, not from habit — and fetch either way.** "What does this branch add?" is three-dot (from the merge base). Two-dot compares tips, so base commits since the fork show up *reversed*. Unrelated subsystems in a focused change mean check the form first.
- **When the question is what the *live* system does, `HEAD` is not the answer.** The checkout may be behind the deploying branch or predate the change asked about. Answer from `git show origin/<deploy-branch>:<path>` after a fetch, or from the running system (served document, live data, resolved config); where they disagree, the running system wins and the gap is the finding.
- **Outgoing commits:** before pushing, review `git log --oneline @{u}..` (or `origin/<base>..HEAD` for a new branch) — every commit must be yours and expected. (Backed by the push author gate.)
- **PRs:** before asserting PR state, run `gh pr view --json state,mergedAt,statusCheckRollup` and answer from that. Read the `[pr-state]` line the hook injects before git/gh writes; if it says MERGED or CLOSED, pause and confirm intent.
- **A tracker's status timestamp is not a deploy date.** Done / `updatedAt` records a card move, not code reaching an environment, and can be weeks off. Date from the merge commit plus the release that carried it (`gh pr view --json mergedAt`, then which release contains it), and state which date you used.
- **When dating a release by "which one contains this commit", enumerate every candidate, and cross-check the answer against the earliest observation of the effect.** Testing a few plausible refs gives a date too late whenever the carrier was not among them. Use `git branch -r --contains` or ancestry over every merge into the deploying branch; a first sighting before your date means the date is wrong.
- **A checkout you did not leave on its current branch is occupied.** Someone may be working in it right now; do not move it — `git worktree add <path> <branch>` costs nothing. Git carries non-conflicting changes across a switch and reports success, so the damage is invisible. (Backed by the branch-switch gate.)

  **The check belongs before the first edit, not before the commit.** The branch can change between turns, and later edits land in whatever is checked out. Read the branch at the start of any editing turn after a gap; if it moved, take a worktree; if you already edited, isolate your paths with a scoped patch and restore only those. (Backed by the edit branch-drift gate.)

## Tooling

- Use the `gh` CLI for all GitHub operations (PRs, issues, checks, releases).
- Multi-line PR/issue bodies: write them to a scratch file and pass `--body-file` — inline `--body` strings get mangled or denied.
- `gh pr edit` can fail **silently** (a Projects-classic GraphQL error, exit as if it worked) — for bodies and for `--add-label`/`--remove-label` alike. Read the field back (`gh pr view <n> --json body,labels`). Labels go through REST instead: `gh api --method POST repos/<owner>/<repo>/issues/<n>/labels -f "labels[]=<name>"`, `DELETE …/issues/<n>/labels/<name>`. For a body, if unchanged, patch via REST: `gh api --method PATCH repos/<owner>/<repo>/pulls/<n> -F body=@<file>`, building the file from `gh api repos/<owner>/<repo>/pulls/<n> | jq -j .body` — `--jq .body` appends a newline that the PATCH writes back, growing the body a byte per edit.
