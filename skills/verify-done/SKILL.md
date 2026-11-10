---
name: verify-done
description: Run the project's real quality gate — the checks CI runs, with the tests scoped to the changed files unless the diff needs the full suite — and report whether this work is done, recording the READY marker the push gate requires. Invoke via /verify-done before pushing any branch; `/verify-done full` forces the full suite.
---

Run the project's real quality gate — the checks CI runs — and report whether this work is done.

Tests run **scoped** by default: only the tests related to the files this branch changes. They run **full** when an edited file can reach tests that are not named after it, or when asked (`/verify-done full`, or `VERIFY_DONE_FULL=1`). Every other check (lint, typecheck, build, …) always runs in full. CI still runs the full suite on the PR; a scoped READY says less than a full one, and the verdict must say which it is.

## 1. The check plan

The plan is cached, because discovery is the expensive step and its inputs are rarely edited:

- Run `"$HOME/.claude/scripts/verify-plan-fingerprint.sh"` (hashes CI workflows, package manifests, lockfiles, and the plan format version).
- If `"$(git rev-parse --git-dir)/verify-done-plan"` exists and its first line equals that fingerprint, go to step 2. `verify-run.sh` re-checks this and exits 3 when the plan is missing, stale, or in the old untagged format — then discover and rewrite it.

Plan format — line 1 is the fingerprint; every other line is tab-separated and tagged:

```
setup<TAB><command>                       install steps; run first, one at a time
check<TAB><command>                       lint, typecheck, build, …; always full
test<TAB><full command>[<TAB><scoped command>]
```

Commands run from the repository root. Use `cd <relative dir> && …` for a subdirectory, never an absolute path. Every `check` and `test` line runs **concurrently**, so one line = one CI job. Steps that share state go on one line, joined with `&&`: steps within one CI job, jobs writing the same build output, and jobs needing the same local database or container.

A scoped command names its inputs with placeholders:

- `{tests}` — the selected test files (shell `*.test.sh` suites, pytest `test_*.py` / `*_test.py`).
- `{files}` — the changed JS/TS-family files, for the runner's own import-graph mapping.

Per runner:

| Runner | full | scoped |
| --- | --- | --- |
| vitest | `pnpm vitest run` | `pnpm vitest related --run {files}` |
| jest | `npx jest` | `npx jest --findRelatedTests {files}` |
| pytest | `pytest` (add `-n auto` only if pytest-xdist is already installed) | `pytest {tests}` |
| shell suites (this config repo) | `bash tests/run-all.sh` | `bash tests/run-all.sh {tests}` |

Use the project's real script and package manager, not these literals. Never add `--passWithNoTests` to a scoped form: when the runner reports no related tests, `verify-run.sh` runs that line's full form instead. Leave the scoped form out when the runner cannot take a file subset, or runs from a subdirectory and cannot take repo-root paths. That line then always runs in full.

Discovery:

- Read `.github/workflows/*.yml` and find every check job: lint, typecheck, tests, build, formatting, anything else.
- Read `package.json` scripts to resolve what each CI step actually executes.
- Detect the package manager from the lockfile (`package-lock.json` → npm, `yarn.lock` → yarn, `pnpm-lock.yaml` → pnpm, `bun.lockb`/`bun.lock` → bun). Never assume npm.
- Do NOT invent checks. If CI doesn't run a formatter, don't run one. If there is no CI config, fall back to the obvious package.json scripts (`lint`, `typecheck`, `test`, `build`) and say you did so.
- Read each job's trigger too (`on:` branches and `paths`, job-level `if:`). A job CI runs only for some changes gets a guarded plan line: run it only when `git diff --name-only origin/<base>...HEAD` matches its `paths` for the event the branch will use, and otherwise print that it was skipped and why. `<base>` is the branch's PR base: for a stacked branch that is the branch below it, not trunk, because CI's path filter sees only the PR's own changed files — diffing a stacked branch against trunk re-triggers the tier for the commits below it. Never cache a path-filtered job unconditionally — it blocks pushes CI would never block, and a job that needs shared local infrastructure (a database, a container stack) fails there for reasons that have nothing to do with the branch.
- Install steps (`npm ci`, `pnpm install --frozen-lockfile`, …) exist because CI runners start empty. Make them `setup` lines and guard them: skip when the installed tree already matches the lockfile, and when `node_modules` is a symlink shared between worktrees, fail with a message instead of reinstalling, since a reinstall there replaces the tree every other checkout uses.

Write the cache: the fingerprint as line 1, then the tagged lines.

## 2. Run the checks

Run `"$HOME/.claude/scripts/verify-run.sh"` (add `--full` for `/verify-done full`; add `--base origin/<branch>` when the PR base is not what `detect-parent-branch.sh` finds). It:

- calls `verify-scope.sh` to pick the mode, and prints the mode and the reason;
- runs `setup` lines one at a time, then every `check` and `test` line at once, with output buffered and printed in plan order;
- prints the full output of every failing line, and only the tail of each passing one;
- ends with `verify-run: result=PASS|FAIL mode=scoped|full [selected=N total=M]`.

The run goes **full** when any changed file is:

- a CI config file (`.github/workflows/*` and the like);
- a package manifest or lockfile (`package.json`, `*.lock`, `pyproject.toml`, `go.mod`, …) or a runtime-version pin;
- test or build config (`tsconfig*.json`, `vitest.config.*`, `jest.config.*`, `babel.config.*`, `conftest.py`, `pytest.ini`, …);
- test infrastructure (`__mocks__/`, `fixtures/`, test helpers, and any non-test file inside a test directory, such as `tests/run-all.sh`);
- a code file with no related test (no test named after it, none naming it, none for a script that sources it).

It also goes full when there is no merge-base with the PR base, when nothing differs from the base, and when the selection is half the test files or more. Docs nobody's test reads (Markdown, images) and deleted files nothing references need no tests and do not escalate.

Any failing line is a failure. Report the failing command and its error output. "Tests pass except one flaky one" is NOT READY.

## 3. Report state

After checks (pass or fail):

- `git status` — list uncommitted changes and untracked files.
- Summarize what changed this session: files touched and a one-line description of each meaningful change (use `git diff --stat` and session context).

## 4. Verdict

End with one of these, always naming the mode — **READY (scoped: N of M test files — <reason>)** or **READY (full — <reason>)**:

- **READY** — all checks pass AND the tracked tree is clean (everything committed). Only this verdict is push-ready.
- **READY TO COMMIT** — all checks pass, but tracked changes are uncommitted. A push publishes commits, not the working tree, so this pass does not certify a push: commit the exact tree the checks ran on, then record (below). Untracked files need an explanation but don't force this verdict — they never alter the pushed commit.
- **NOT READY** — name exactly what's blocking: the failed check, or unexplained uncommitted/untracked files.

## 5. Record the verdict

The pre-push-verify-gate hook blocks pushes without a fresh READY marker — record the verdict so the gate reflects reality:

- **READY** → run `"$HOME/.claude/scripts/record-verify-pass.sh" --mode <scoped|full>` with the mode `verify-run.sh` reported on its last line. It writes the marker only for a clean tracked tree and refuses otherwise. A refusal means the verdict was actually READY TO COMMIT; never write the marker by hand to get around it.
- **READY TO COMMIT** → commit, then run the recorder — but only if nothing except the commit itself touched the tree since the checks passed; the committed content is then exactly what was checked. If anything else changed the tree (formatter, codegen, install), re-run the checks first. A scoped selection was computed from the changed files, and committing them does not alter the set.
- **NOT READY** → `rm -f "$(git rev-parse --git-dir)/verify-done-ok"`

The marker records the exact commit you verified (line 1, the HEAD SHA) and the mode (line 2, `mode=scoped|full`). The gate trusts it only while HEAD still matches, so a later commit, amend, or rebase invalidates it — re-run /verify-done and re-record after any of those. Do not write the marker on a NOT READY verdict for any reason — the marker IS the READY verdict. Any Write/Edit after recording also deletes it automatically.

Record the marker as its **own** Bash command, then push separately — PreToolUse gates run before a command executes, so a marker written in the same command as the push does not exist yet when the gate checks for it.
