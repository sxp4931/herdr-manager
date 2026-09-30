# Progress

Entries record the milestone message and the HEAD that preceded the commit. The resulting hash is read from `git log`.

## Milestone 01 — Bootstrap a runnable loopback repository

- Status: complete
- Date (UTC): 2026-09-29
- Preceding HEAD: none (repository has no commits yet)
- Commit message: `chore: bootstrap Linux dashboard workspace`
- Commands and results:
  - `npm install --no-audit --no-fund` with npm 10.9.3 — exit 0 after the exact `vitest@4.1.11` override (see `docs/DECISIONS.md`). Produced `package-lock.json` lockfileVersion 3.
  - `npm ci --no-audit --no-fund` with npm 10.9.3 — exit 0. Lockfile hash unchanged. The same `npm ci` with host npm 9.2.0 also exited 0 and left the lockfile unchanged (engine warning only).
  - `python3 -m venv .venv && .venv/bin/python -m pip install -r probes/requirements.txt` — exit 0. Python 3.13.5, pyte 0.8.2, wcwidth 0.2.13.
  - `npm exec playwright install chromium` — exit 0. Chromium headless shell installed.
  - `npm run check` — exit 0. Lint, typecheck, unit (2 passed), Python (1 passed), build (`apps/server/dist/main.js`, `apps/web/dist/index.html`), integration (1 passed). Zero failures, zero skips.
  - `npm run test:e2e -- tests/e2e/dashboard.spec.ts` — exit 0. 1 passed. Title `herdr dashboard` on the production build.
  - `node scripts/preflight.mjs --json` — exit 0. `coreReady` true, `platform` linux. Optional herdr unavailable; claude, codex, grok, and tmux reported available. No live probe was launched.
  - `node scripts/preflight.mjs --require-core` — exit 0.
  - `node scripts/check-policy.mjs` — exit 0.
- Notes: fixtures are not involved yet. SQLite availability was checked with an in-memory `node:sqlite` database. Node prints an experimental-SQLite warning on stderr; it does not change the JSON result.

## Milestone 02 — Define normalized contracts and deterministic fixture catalog

- Status: complete
- Date (UTC): 2026-09-29
- Preceding HEAD: `868bd0c` `chore: bootstrap Linux dashboard workspace`
- Commit message: `feat: define quota and herd contracts`
- Commands and results:
  - `npm run test:unit -- tests/unit/contracts.test.ts` — exit 0. 9 passed, 0 failed, 0 skipped.
  - `npm run check` — exit 0. Lint, typecheck, unit (9), Python (1), build, integration (1).
- Results: daily snapshot has exactly Claude, Codex, and Grok. Claude 5h is 10% used and weekly is 20% used. Codex 5h is 65% left (35% used / 65% remaining) and weekly is 75% left. Grok weekly is 15% used and the 5h window is `not_applicable` with null percentages. Unknown banked inventory is null; the partial Codex inventory is a known empty array. Invalid percents, invalid dates, missing provenance, and zero-for-unknown are rejected. Scenario files are synthetic fixtures, not live-account captures. The milestone also drops an accidentally tracked Python bytecode file from the tree.

## Milestone 03 — Add local SQLite storage, migrations, and redaction

- Status: complete
- Date (UTC): 2026-09-29
- Preceding HEAD: `36d7a55` `feat: define quota and herd contracts`
- Commit message: `feat: persist sanitized observations locally`
- Commands and results:
  - `npm run test:unit -- tests/unit/redaction.test.ts` — exit 0. 3 passed, 0 failed, 0 skipped.
  - `npm run test:integration -- tests/integration/sqlite.test.ts` — exit 0. 4 passed, 0 failed, 0 skipped.
  - `npm run check` — exit 0. Unit 12 passed. Python 1 passed. Integration 5 passed.
- Results: migration `001` applies twice and leaves one `schema_migrations` row. Restart keeps the quota sample and the original session dwell; a changed session identity resets dwell; an older observation does not overwrite a newer one. A sample older than seven days is pruned. The database file and WAL are mode `0600` and the directory is `0700`. A corrupt file raises `StorageCorruptionError` and is not deleted. A locked database fails inside five seconds and is left in place. Stored bytes, log lines, read-back JSON, and the HTTP 404 body do not contain `SYNTHETIC_SECRET_SENTINEL`. Fixture data only.

## Milestone 04 — Bound process execution and configuration

- Status: complete
- Date (UTC): 2026-09-29
- Preceding HEAD: `bfa7baa` `feat: persist sanitized observations locally`
- Commit message: `feat: constrain local collector execution`
- Commands and results:
  - `npm run test:integration -- tests/integration/probe-boundary.test.ts` — exit 0. 7 passed, 0 failed, 0 skipped.
  - `npm run check:policy` — exit 0. `policy ok`.
  - `npm run check` — exit 0. Unit 12 passed. Python 1 passed. Integration 12 passed.
- Results: the example config keeps probes disabled, mode `passive`, and host `127.0.0.1`. A `0.0.0.0` host is rejected. Fixture mode without `HERDR_FIXTURE=1` is rejected, and that env forces fixture mode. A shell metacharacter stayed a literal argv entry and did not create a sentinel file. API keys, `OPENAI_BASE_URL`, and `GIT_CONFIG_COUNT` were stripped. A flooded child was truncated at 1024 bytes and killed. A timed-out process group, including its `sleep` child, was reaped. Shells, `git reset`, `git -c` config overrides, `git log -p`, and `tmux send-keys` are denied before spawn. `tmux -S <socket> list-panes` is allowed and did not create a server socket. A world-writable working directory is rejected. `node scripts/probe-doctor.mjs --json` reported three providers with `liveProbe: false` and did not launch a CLI. `--live` exits 2. No live usage probe was run.

## Milestone 05 — Collect git repositories and worktrees

- Status: complete
- Date (UTC): 2026-09-29
- Preceding HEAD: `2a9aea1` `feat: constrain local collector execution`
- Commit message: `feat: collect git worktree activity`
- Commands and results:
  - `npm run test:integration -- tests/integration/git.test.ts` — exit 0. 4 passed, 0 failed, 0 skipped.
  - `npm run check` — exit 0. Unit 12 passed. Python 1 passed. Integration 17 passed.
- Results: a synthetic temporary repository produced exactly two allowed worktrees on distinct branches, with main counts 1 staged / 1 modified / 1 untracked and the feature worktree counting a rename plus a staged-and-modified file as 2 staged / 1 modified. A filename containing a space and a filename containing a newline stayed one status record each. The outside worktree was returned as disabled `outside_root` and was never passed to `status` or `log`. HEAD, porcelain status, and worktree file bytes were unchanged. A separate conflict fixture counted 1 conflict. Detached HEAD, an unborn branch, a locked worktree, a missing prunable path, an empty directory, and an empty root list were reported without writing. Commit subjects redact `SYNTHETIC_SECRET_SENTINEL`. The fixture author is local to the temporary repo. No live account data.
