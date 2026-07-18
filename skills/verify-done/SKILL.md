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

- **READY** — all CI checks pass, working tree state is explained (committed, or intentionally uncommitted with a reason).
- **NOT READY** — name exactly what's blocking: the failed check, or unexplained uncommitted/untracked files.

Be honest. "Tests pass except one flaky one" is NOT READY.

## 5. Record the verdict

The pre-push-verify-gate hook blocks pushes without a fresh READY marker — record the verdict so the gate reflects reality:

- **READY** → `date > "$(git rev-parse --git-dir)/verify-done-ok"`
- **NOT READY** → `rm -f "$(git rev-parse --git-dir)/verify-done-ok"`

Do not write the marker on a NOT READY verdict for any reason — the marker IS the READY verdict. Any Write/Edit after recording invalidates the marker automatically; re-run this command after further changes.
