# Git Conventions

**When to apply:** every commit, branch operation, or pull-request action.

## Commits

- Conventional commits format (`feat:`, `fix:`, `refactor:`, `docs:`, `chore:`, `test:`, `ci:`). Scope optional: `feat(auth): add token refresh`. (Enforced by hook.)
- Immediately before committing, review `git diff --cached --stat` — the index may hold earlier staged changes (a stray `git rm`, a forgotten `add`) that would ride along. Commit exactly what the message describes.
- **Never add Co-Authored-By or any AI attribution** — commits, PR titles/descriptions, issues, comments. This includes the "Generated with Claude Code" footer harnesses append by default. (Enforced by hook.)
- Never commit directly to `main`/`master` — verify the branch first, use a feature branch. (Enforced by hook.)
- Autonomous commit, push, and PR creation are allowed by default — no separate "now commit/push" instruction is needed. Before pushing: work on a feature branch, run `/verify-done`, and let the gates pass. Still **never** auto-merge (the user merges) and never push to the default branch; force pushes to feature branches need no asking. A project that wants a human checkpoint can re-require explicit instructions in its own CLAUDE.md.
- **Never route around a gate.** When a hook blocks a git operation, do not re-issue it through wrapper scripts, alternate command forms, or anything else that hides the operation from the gates. Fix the trigger instead (feature branch, ff-merge) or hand the exact command to the user to run with the `!` prefix.

## Branches and PRs

- Never push to the default branch — feature branch + PR, always. (Enforced by hook.)
- Force pushes to feature branches are allowed without asking — bare `--force` included, though prefer `--force-with-lease` when the remote may have moved (it fails instead of clobbering unseen commits). Never force-push the default branch or any protected branch — pushes targeting the default branch are blocked outright (hook + deny rules).
- To undo commits, use `git reset --soft` (keeps changes staged). Never `git reset --hard` — it destroys work and is deny-blocked; if a hard discard is truly needed, ask the user to run it themselves.
- Never merge PRs — the user merges manually. (Enforced by hook.)
- Never close/reopen a PR (or otherwise manipulate PR open/closed state) to work around tooling — it notifies reviewers and can re-trigger full CI pipelines. A stale CI result clears on the next `synchronize` (push) event or an explicit re-run; if neither fits, ask before touching PR state.
- One PR = one concern. Once a PR is open, a new request gets a new branch off main — only add commits to an open PR when the user explicitly says to. An open PR can merge at any moment; commits stacked on its branch strand.
- When branching off a protected base (`develop`/`main`) — including via `git worktree add -b <branch> <path> origin/<base>` — don't leave the feature branch tracking the protected branch; unset the upstream (`git branch --unset-upstream`) so a bare `git push` can't target it.
- Rebase onto the target branch (`git fetch origin main && git rebase origin/main`) before creating a PR.
- Run `/verify-done` before pushing any branch. (Enforced by hook — a READY verdict records a marker that pushes require; any edit invalidates it. The marker is only minted for a clean tracked tree: checks that passed on a dirty tree get READY TO COMMIT, not push-ready READY.)
- **Decide the destination of every working-tree change before starting a commit flow.** Push-ready READY requires a clean tracked tree, so deliberately leaving something uncommitted (a borrowed fix from another branch, a local experiment) dead-ends at the gate by construction. Raise the choice — commit it, drop it, or hand the push over — when the user asks to commit, not after the gate refuses.
- PR descriptions: bullet points in the summary, not prose paragraphs.
- After pushing new commits to an existing PR, update its title and description (`gh pr edit`) to reflect all changes.
- If the repo has a PR template, use it.

## State freshness

State from earlier in the conversation goes stale — and so do local clones.

- **Repos:** before analyzing, comparing, or building on any repo — including at the start of a task and after any conversation gap — run `git fetch` and `git status -sb` first. A stale clone produces conclusions upstream has already invalidated; analysis done on it is wasted.
- **Outgoing commits:** before pushing a branch, review `git log --oneline @{u}..` (or `origin/<base>..HEAD` for a new branch) — every commit must be yours and expected. Local history can be polluted by tooling without the working tree ever looking dirty. (Backed by the push author gate.)
- **PRs:** before asserting PR state (open/merged/checks-passing), run `gh pr view --json state,mergedAt,statusCheckRollup` and answer from that output, not memory. The pre-git-state-refresh hook injects a `[pr-state]` line before git/gh writes — read it; if it reports MERGED or CLOSED, pause and confirm intent.
- **A checkout you did not leave on its current branch is occupied.** Finding the primary checkout on someone else's branch means someone else is working in it, possibly right now — a `git status` from earlier in the session is not evidence it is idle, because the edit that matters may land in the minute between the reading and the switch. Do not move it: `git worktree add <path> <branch>` gives you your own tree and costs nothing. This matters because git does not stop you — when the changes don't conflict it carries them onto the target branch and reports success, so the failure is invisible until someone finds their work committed on a branch they never touched. (Backed by the branch-switch gate, which blocks the switch while tracked files are modified.)

## Tooling

- Use the `gh` CLI for all GitHub operations (PRs, issues, checks, releases).
- Multi-line PR/issue bodies: write them to a scratch file and pass `--body-file` — inline `--body` strings full of backticks and quotes get mangled or denied by the permission layer.
- `gh pr edit` can fail **silently**: on some repo/`gh` version combinations it aborts on a Projects-classic GraphQL error while still exiting as if it worked, leaving the old description in place. After any `gh pr edit`, read the field back (`gh pr view <n> --json body`) and confirm the change landed. If it did not, patch via REST instead: `gh api --method PATCH repos/<owner>/<repo>/pulls/<n> -F body=@<file>`.
