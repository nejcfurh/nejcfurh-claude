# Git Conventions

**When to apply:** every commit, branch operation, or pull-request action.

## Commits

- Conventional commits format (`feat:`, `fix:`, `refactor:`, `docs:`, `chore:`, `test:`, `ci:`). Scope optional: `feat(auth): add token refresh`. (Enforced by hook.)
- **Never add Co-Authored-By or any AI attribution** — commits, PR titles/descriptions, issues, comments. This includes the "Generated with Claude Code" footer harnesses append by default. (Enforced by hook.)
- Never commit directly to `main`/`master` — verify the branch first, use a feature branch. (Enforced by hook.)
- Never auto-commit or push — wait for explicit instructions.
- **Never route around a gate.** When a hook blocks a git operation, do not re-issue it through wrapper scripts, alternate command forms, or anything else that hides the operation from the gates. Fix the trigger instead (feature branch, ff-merge) or hand the exact command to the user to run with the `!` prefix.

## Branches and PRs

- Never push to the default branch — feature branch + PR, always. (Enforced by hook.)
- Never force-push without asking immediately before the push — plan approval is not push approval. One exception: `/rebase` may push the current feature branch with `--force-with-lease` after a **conflict-free** rebase; pushes after manual conflict resolution still require confirmation. Never bare `--force` (enforced by hook), never a protected branch.
- To undo commits, use `git reset --soft` (keeps changes staged). Never `git reset --hard` — it destroys work and is deny-blocked; if a hard discard is truly needed, ask the user to run it themselves.
- Never merge PRs — the user merges manually. (Enforced by hook.)
- Rebase onto the target branch (`git fetch origin main && git rebase origin/main`) before creating a PR.
- Run `/verify-done` before pushing any branch. (Enforced by hook — a READY verdict records a marker that pushes require; any edit invalidates it.)
- PR descriptions: bullet points in the summary, not prose paragraphs.
- After pushing new commits to an existing PR, update its title and description (`gh pr edit`) to reflect all changes.
- If the repo has a PR template, use it.

## State freshness

State from earlier in the conversation goes stale — and so do local clones.

- **Repos:** before analyzing, comparing, or building on any repo — including at the start of a task and after any conversation gap — run `git fetch` and `git status -sb` first. A stale clone produces conclusions upstream has already invalidated; analysis done on it is wasted.
- **Outgoing commits:** before pushing a branch, review `git log --oneline @{u}..` (or `origin/<base>..HEAD` for a new branch) — every commit must be yours and expected. Local history can be polluted by tooling without the working tree ever looking dirty. (Backed by the push author gate.)
- **PRs:** before asserting PR state (open/merged/checks-passing), run `gh pr view --json state,mergedAt,statusCheckRollup` and answer from that output, not memory. The pre-git-state-refresh hook injects a `[pr-state]` line before git/gh writes — read it; if it reports MERGED or CLOSED, pause and confirm intent.

## Tooling

- Use the `gh` CLI for all GitHub operations (PRs, issues, checks, releases).
