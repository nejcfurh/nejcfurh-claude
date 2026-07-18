---
name: rebase
description: Rebase the current feature branch onto its base branch and resolve any merge conflicts with full verification. Use when the user says "rebase", "update my branch", "sync with main", or a PR reports conflicts with the base branch.
---

Rebase the current branch onto its base: $ARGUMENTS

## Base branch

- If the user named a base, use it verbatim (prefix bare branch names with `origin/`).
- Otherwise: if an open PR exists for this branch, use its base (`gh pr view --json baseRefName`); else run `~/.claude/scripts/detect-parent-branch.sh` (stacked-PR aware — reads the base from stdout, `warning:` lines are informational).

## Pre-flight (stop on first failure)

1. Inside a git repo, not detached HEAD, and not on `main`/`master` — never rebase the default branch itself.
2. Working tree clean (`git status --porcelain`). If dirty, offer `git stash -u` and wait for the user's answer — never auto-stash.
3. No rebase/merge/cherry-pick already in progress (`.git/rebase-merge`, `.git/rebase-apply`, `MERGE_HEAD`, `CHERRY_PICK_HEAD`).
4. `git fetch origin <base>`.
5. If `git rev-list --count HEAD..origin/<base>` is 0, report "already up to date" and stop.

## Rebase

Run `git rebase origin/<base>`.

**Clean path (no conflicts):** show the new commit range (`git log --oneline origin/<base>..HEAD`). If the rebase brought in changes to `package.json` or a lockfile (`git diff --name-only ORIG_HEAD HEAD`), reinstall with the project's package manager. Then push with `git push --force-with-lease` (set upstream if missing). Never bare `--force`; if the lease is rejected, the remote moved — stop and report, do not retry harder.

**Conflict path:** resolve every conflicted commit the rebase stops on, one file at a time:

1. **Understand both sides** — read the conflicted hunks, then the intent behind each: `git log --left-right --oneline HEAD...origin/<base> -- <file>` and the surrounding code.
2. **Resolve on the merits** — keep ours, keep theirs, or weave both, based on what each change was trying to do. Never blind-pick a side for a non-trivial hunk. Lockfile conflicts: resolve `package.json` first, then regenerate the lockfile by reinstalling rather than hand-merging it.
3. **Sweep for leftovers** — no `<<<<<<<`/`=======`/`>>>>>>>` markers anywhere (`git grep`), then stage and `git rebase --continue`. Repeat for the next stop.
4. **Verify semantically, not just textually** — after the rebase completes: reinstall dependencies if any manifest changed (stale `node_modules` produces phantom type errors in untouched files — reinstall before debugging those), then typecheck and run the tests. Code can merge cleanly and still be broken (a renamed function, a changed signature).
5. **Report and confirm** — summarize each conflict and how it was resolved (file, both intents, decision). Because conflict resolutions are judgment calls, ask before force-pushing on this path; push with `--force-with-lease` once confirmed.

If a resolution can't be made safely (both sides rewrote the same logic with incompatible intent), stop, `git rebase --abort` if the user prefers, and lay out the options — never guess through a hunk you don't understand.
