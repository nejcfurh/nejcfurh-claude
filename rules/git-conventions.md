# Git Conventions

**When to apply:** every commit, branch operation, or pull-request action.

## Commits

- Conventional commits format (`feat:`, `fix:`, `refactor:`, `docs:`, `chore:`, `test:`, `ci:`). Scope optional: `feat(auth): add token refresh`. (Enforced by hook.)
- Immediately before committing, review `git diff --cached --stat` — the index may hold earlier staged changes (a stray `git rm`, a forgotten `add`) that would ride along. Commit exactly what the message describes.
- **Never add Co-Authored-By or any AI attribution** — commits, PR titles/descriptions, issues, comments. This includes the "Generated with Claude Code" footer harnesses append by default. (Enforced by hook.)
- Never commit directly to `main`/`master` — verify the branch first, use a feature branch. (Enforced by hook.)
- Autonomous commit, push, and PR creation are allowed by default — no separate "now commit/push" instruction is needed. Before pushing: work on a feature branch, run `/verify-done`, and let the gates pass. Still **never** auto-merge (the user merges) and never push to the default branch; force pushes to feature branches need no asking. A project that wants a human checkpoint can re-require explicit instructions in its own CLAUDE.md.
- **Never route around a gate.** When a hook blocks a git operation, do not re-issue it through wrapper scripts, alternate command forms, or anything else that hides the operation from the gates. Fix the trigger instead (feature branch, ff-merge) or hand the exact command to the user to run with the `!` prefix. A commit made by a tool other than `git commit` is an alternate command form, whether or not you meant it as one: `gh stack init|add -A -m …` writes a real commit on a command line containing no `commit`, so the branch, co-author, message and secret gates all sit it out. Stage and commit separately. (Gated.)

## Branches and PRs

- Never push to the default branch — feature branch + PR, always. (Enforced by hook.)
- Force pushes to feature branches are allowed without asking — bare `--force` included, though prefer `--force-with-lease` when the remote may have moved (it fails instead of clobbering unseen commits). Never force-push the default branch or any protected branch — pushes targeting the default branch are blocked outright (hook + deny rules).
- To undo commits, use `git reset --soft` (keeps changes staged). Never `git reset --hard` — it destroys work and is deny-blocked; if a hard discard is truly needed, ask the user to run it themselves.
- Never merge PRs — the user merges manually. (Enforced by hook.)
- Never close/reopen a PR (or otherwise manipulate PR open/closed state) to work around tooling — it notifies reviewers and can re-trigger full CI pipelines. A stale CI result clears on the next `synchronize` (push) event or an explicit re-run; if neither fits, ask before touching PR state.
- One PR = one concern. Once a PR is open, a new request gets a new branch off main — only add commits to an open PR when the user explicitly says to. An open PR can merge at any moment; commits stacked on its branch strand. When the new work genuinely *depends* on the open PR, neither of those is the answer: stack it (below), because branching off the trunk strands the work and adding commits breaks the one-concern boundary.
- When branching off a protected base (`develop`/`main`) — including via `git worktree add -b <branch> <path> origin/<base>` — don't leave the feature branch tracking the protected branch; unset the upstream (`git branch --unset-upstream`) so a bare `git push` can't target it.
- Rebase onto the target branch (`git fetch origin main && git rebase origin/main`) before creating a PR.
- Run `/verify-done` before pushing any branch. (Enforced by hook — a READY verdict records a marker that pushes require; any edit invalidates it. The marker is only minted for a clean tracked tree: checks that passed on a dirty tree get READY TO COMMIT, not push-ready READY.)
- **Decide the destination of every working-tree change before starting a commit flow.** Push-ready READY requires a clean tracked tree, so deliberately leaving something uncommitted (a borrowed fix from another branch, a local experiment) dead-ends at the gate by construction. Raise the choice — commit it, drop it, or hand the push over — when the user asks to commit, not after the gate refuses.
- PR descriptions: bullet points in the summary, not prose paragraphs.
- After pushing new commits to an existing PR, update its title and description (`gh pr edit`) to reflect all changes.
- If the repo has a PR template, use it.

## Stacking

A stack is how dependent concerns stay separately reviewable instead of collapsing into one diff — it does not relax "one PR = one concern", it is what makes the rule survive dependent work. Default to one when any of these holds:

- the work runs past ~30 files or ~1000 lines
- new work depends on a PR that is already open
- a branch has grown into concerns a reviewer would want to judge one at a time

Reviewability is the thing being optimised. Two PRs that each read in one sitting beat one that nobody finishes.

**Mechanics.** `gh stack` (`gh extension install github/gh-stack`) owns branch topology; `git add` + `git commit` own content. Never `gh stack init|add -A -m` — it commits behind the gates.

**Slicing.**

- **Order bottom-up, trunk first:** dependencies and config → schema and migrations → data access → API and business logic → UI → tests and docs that belong to no slice above.
- **The seam test.** Every slice must build and pass on its own, referencing nothing introduced above it. If two candidate slices cannot both satisfy that, they are one slice. A stack whose middle PR does not compile is worse than a single large PR, so prefer fewer, larger slices over more slices that fail the seam test.
- **No ordinals in branch names.** Position lives in each PR's base, and a `-1-`/`-2-` prefix goes stale the moment a slice is inserted, dropped or reordered. Share a stem across the slice names so the stack reads as one group.
- **Each PR body covers only its own slice**, and states its position and what it sits on — reviewers read bottom-up and need to know what is not theirs to review.
- **Slicing an existing branch is restructuring.** Propose the slice plan and get approval before mutating anything, take a backup ref first, and say what the ref is.
- **How it merges depends on whether the host knows it is a stack.** A *registered* stack merges atomically: merging any PR lands it together with every unmerged PR below it in one all-or-nothing operation, and the next PR up is re-based onto the trunk for you — so one click on the top PR can land the whole stack, and there is nothing to do bottom-up by hand. A chain you merely based on each other is not that: merge it bottom-up, one at a time, re-basing what remains after each. Check which you have before planning the merge; the difference is one API field, and assuming the manual case turns a one-click merge into an afternoon.
- **Read the allowed merge methods off the base branch's ruleset, not the repo settings.** A ruleset can narrow a repo that advertises merge/squash/rebase down to one method, and it is the ruleset that governs. Squash is the fragile choice on a stack in any case — it replaces the exact commits the upper branches are based on — so confirm it is both permitted and supported before choosing it.

## State freshness

State from earlier in the conversation goes stale — and so do local clones.

- **External state a handoff hands you is unverified, not established.** A handoff or an earlier session saying an external object does not exist — a flag, a dashboard, a queue, a third-party record — is a claim about a system that other people also change, and it decays the moment it is written. Re-read it from the owning system before repeating it, and certainly before building a plan item around creating it or writing it into a durable artifact. The failure is quiet and expensive: the object already existed, configured correctly by someone else, and every downstream statement inherited the error.

- **Repos:** before analyzing, comparing, or building on any repo — including at the start of a task and after any conversation gap — run `git fetch` and `git status -sb` first. A stale clone produces conclusions upstream has already invalidated; analysis done on it is wasted.
- **Outgoing commits:** before pushing a branch, review `git log --oneline @{u}..` (or `origin/<base>..HEAD` for a new branch) — every commit must be yours and expected. Local history can be polluted by tooling without the working tree ever looking dirty. (Backed by the push author gate.)
- **PRs:** before asserting PR state (open/merged/checks-passing), run `gh pr view --json state,mergedAt,statusCheckRollup` and answer from that output, not memory. The pre-git-state-refresh hook injects a `[pr-state]` line before git/gh writes — read it; if it reports MERGED or CLOSED, pause and confirm intent.
- **A tracker's status timestamp is not a deploy date.** An issue marked Done, or its `updatedAt`, records when a human moved a card — not when the code reached an environment. Deriving one from the other can be wrong by weeks, and it silently invalidates any before/after measurement built on it, including one handed to a delegate who will not re-check it. Get the real date from the merge commit plus the release that carried it to the deploying branch (`gh pr view --json mergedAt`, then which release contains that commit), and state which date you used and how you got it.
- **A checkout you did not leave on its current branch is occupied.** Finding the primary checkout on someone else's branch means someone else is working in it, possibly right now — a `git status` from earlier in the session is not evidence it is idle, because the edit that matters may land in the minute between the reading and the switch. Do not move it: `git worktree add <path> <branch>` gives you your own tree and costs nothing. This matters because git does not stop you — when the changes don't conflict it carries them onto the target branch and reports success, so the failure is invisible until someone finds their work committed on a branch they never touched. (Backed by the branch-switch gate, which blocks the switch while tracked files are modified.)

## Tooling

- Use the `gh` CLI for all GitHub operations (PRs, issues, checks, releases).
- Multi-line PR/issue bodies: write them to a scratch file and pass `--body-file` — inline `--body` strings full of backticks and quotes get mangled or denied by the permission layer.
- `gh pr edit` can fail **silently**: on some repo/`gh` version combinations it aborts on a Projects-classic GraphQL error while still exiting as if it worked, leaving the old description in place. After any `gh pr edit`, read the field back (`gh pr view <n> --json body`) and confirm the change landed. If it did not, patch via REST instead: `gh api --method PATCH repos/<owner>/<repo>/pulls/<n> -F body=@<file>`.
