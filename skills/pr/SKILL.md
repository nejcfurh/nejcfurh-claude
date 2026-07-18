---
name: pr
description: Commit outstanding work and open a GitHub pull request with an auto-detected base branch (stacked-PR aware). Invoke when the user says "open a PR", "create a pull request", or "PR this". For the full pre-release gate use ship instead.
---

Open a pull request: $ARGUMENTS

Options: `--draft` (draft PR), `--base <branch>` (explicit base).

## Pre-flight (each as its own check; stop and report on failure)

1. On a feature branch, not `main`/`master`.
2. `gh auth status` succeeds.
3. No open PR already exists for this branch (`gh pr list --head <branch> --state open`) — if one does, report its URL and stop; new commits just need a push.
4. Something to ship: uncommitted changes, or commits ahead of the remote.

## Steps

1. **Commit** any outstanding changes using the `commit` skill (its type decision tree and splitting rules apply), then push with upstream tracking.
2. **Base branch**: use `--base` if given; otherwise run `~/.claude/scripts/detect-parent-branch.sh` — it prints the base on stdout (stacked-PR aware: it picks the closest ancestor among the default branch and open PR heads; `warning:` lines on stderr are informational).
3. **Rebase check**: if the branch is behind the base, offer `/rebase` before creating the PR.
4. **Create**: `gh pr create --base <base>` with a title in conventional-commit style (from the branch's main commit) and a bulleted `## Summary` body describing what changed and why. Use the repo's PR template if one exists. No file-change statistics, no test-status boilerplate, no AI attribution.
5. **Report** the PR URL.

Never merge the PR — the user merges.
