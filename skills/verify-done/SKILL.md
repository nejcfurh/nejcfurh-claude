---
name: verify-done
description: Run the project's real quality gate — the exact checks CI runs — and report whether this work is done, recording the READY marker the push gate requires. Invoke via /verify-done before pushing any branch.
---

Run the project's real quality gate — the exact checks CI runs — and report whether this work is done.

## 1. Discover what CI actually runs

- Read `.github/workflows/*.yml` and find every check job: lint, typecheck, tests, build, formatting, anything else.
- Read `package.json` scripts to resolve what each CI step actually executes.
- Detect the package manager from the lockfile (`package-lock.json` → npm, `yarn.lock` → yarn, `pnpm-lock.yaml` → pnpm, `bun.lockb`/`bun.lock` → bun). Never assume npm.
- Do NOT invent checks. If CI doesn't run a formatter, don't run one. If there is no CI config, fall back to the obvious package.json scripts (`lint`, `typecheck`, `test`, `build`) and say you did so.

## 2. Run the checks

- Run exactly the commands CI runs, in the same order CI runs them.
- Stop at the first failure. Report the failing command and the relevant error output — don't continue to later checks.

## 3. Report state

After checks (pass or fail):

- `git status` — list uncommitted changes and untracked files.
- Summarize what changed this session: files touched and a one-line description of each meaningful change (use `git diff --stat` and session context).

## 4. Verdict

End with one of:

- **READY** — all CI checks pass AND the tracked tree is clean (everything committed). Only this verdict is push-ready.
- **READY TO COMMIT** — all CI checks pass, but tracked changes are uncommitted. A push publishes commits, not the working tree, so this pass does not certify a push: commit the exact tree the checks ran on, then record (below). Untracked files need an explanation but don't force this verdict — they never alter the pushed commit.
- **NOT READY** — name exactly what's blocking: the failed check, or unexplained uncommitted/untracked files.

Be honest. "Tests pass except one flaky one" is NOT READY.

## 5. Record the verdict

The pre-push-verify-gate hook blocks pushes without a fresh READY marker — record the verdict so the gate reflects reality:

- **READY** → run `"$HOME/.claude/scripts/record-verify-pass.sh"` — it writes the marker only for a clean tracked tree and refuses otherwise. A refusal means the verdict was actually READY TO COMMIT; never write the marker by hand to get around it.
- **READY TO COMMIT** → commit, then run the recorder — but only if nothing except the commit itself touched the tree since the checks passed; the committed content is then exactly what was checked. If anything else changed the tree (formatter, codegen, install), re-run the checks first.
- **NOT READY** → `rm -f "$(git rev-parse --git-dir)/verify-done-ok"`

The marker records the exact commit you verified (its first line is the HEAD SHA). The gate trusts it only while HEAD still matches, so a later commit, amend, or rebase invalidates it — re-run /verify-done and re-record after any of those. Do not write the marker on a NOT READY verdict for any reason — the marker IS the READY verdict. Any Write/Edit after recording also deletes it automatically.

Record the marker as its **own** Bash command, then push separately — PreToolUse gates run before a command executes, so a marker written in the same command as the push does not exist yet when the gate checks for it.
