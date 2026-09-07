---
name: ship
description: Full pre-release gate before merging or releasing, run in order — /verify-done, rebase onto the target branch, a security-checklist pass over the diff, a self-review for scope creep and debug leftovers, stale-doc and version updates, then opens the PR. Invoke when the user says "ship", "release", or "ready to merge". Use /pr to only open a pull request, /commit to only commit and push, /verify-done to only run the checks; ship is the superset, stops at the first failing step, and never merges — it hands back the PR URL.
---

Ship: $ARGUMENTS

Run every step in order. Stop and report if any step fails.

## 1. Verify

Run `/verify-done`. Proceed only on READY — a READY TO COMMIT verdict means commit first and re-record; NOT READY stops the ship.

## 2. Git hygiene

- Confirm you're on a feature branch, not the default branch.
- Rebase onto the target branch (`git fetch` + rebase); resolve conflicts and re-run the checks if the rebase changed anything.
- History is clean conventional commits — squash fixup noise ("wip", "fix typo") if present.

## 3. Security pass

Review the full diff against `./security-checklist.md` (in this skill's directory). For changes touching auth, sessions, payments, file uploads, user input handling, or crypto, offer to spawn the `cybersecurity-expert` subagent for a deeper review.

## 4. Self-review

Read the complete diff (`git diff <target>...HEAD`) as a reviewer would. Hunt for:

- Scope creep — changes unrelated to the stated intent.
- Leftover debug code: `console.log`, debug flags, temporary hacks.
- Commented-out blocks and dead code.
- Stray TODOs that should be resolved or ticketed.

Fix what you find; re-run checks if you changed code.

## 5. Docs

Update anything the change made stale: README, API docs, env-var examples, config samples, inline docs.

## 6. Version

If the project versions its releases (version field, changelog, release tags), bump appropriately per its convention (semver, changesets, etc.). Skip if it doesn't.

## 7. Open the PR

Use `gh pr create` against the target branch. Body: a bulleted summary of what changed and why, test notes, and the repo's PR template if `.github/PULL_REQUEST_TEMPLATE.md` exists.

**Never merge.** Present the PR URL; the user merges.
