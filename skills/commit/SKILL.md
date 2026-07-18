---
name: commit
description: Stage, commit, and push changes with well-chosen conventional commit messages. Invoke when the user says "commit", "commit this", "save my changes", or "commit and push".
---

Commit the current changes: $ARGUMENTS

## Pre-flight

1. Never on `main`/`master` — the branch gate enforces this; if on it, create a feature branch first.
2. `git status` — if nothing is staged, stage all modified and new files; if the user already staged specific files, commit only those.
3. Read the full diff of what's being committed before writing any message.

## One commit or several?

If the diff contains distinct logical changes (different concerns, different types — a feature plus an unrelated cleanup, source plus docs), propose splitting into separate commits and stage/commit them one at a time. One purpose per commit.

## Choosing the type (decision tree)

`feat` and `fix` are release-log entries — reserve them for changes that affect users or business logic:

1. Does this branch already have a `feat`/`fix` commit (`git log --oneline`)? → use a supporting type for follow-up work (`refactor`, `test`, `docs`, `chore`, `style`, `perf`, `build`, `ci`).
2. Does the change affect user-facing behavior or business logic (features, bug fixes, API changes)? → `feat` or `fix`.
3. Everything else is a supporting type: internal tooling → `chore`/`build`/`ci`, restructuring → `refactor`, dependencies → `build`, docs → `docs`, tests → `test`, performance → `perf`.

A branch ideally carries one `feat` or `fix` that names its main change, with supporting commits around it.

## Message

- `<type>(scope): <subject>` — scope reflects the module/area touched (lowercase, 1-2 words, consistent with the repo's history: check `git log --oneline -15`).
- Subject in imperative mood, no trailing period, target ≤50 characters for the whole first line.
- Body (blank line after subject) only when the why isn't obvious from the diff.
- Never any AI attribution (the coauthor gate enforces this).

## Push

Push after committing (`git push`, set upstream if missing) unless the user said commit-only. The push gate runs lint/typecheck/tests/build automatically; if it blocks, fix the failures — don't bypass.
