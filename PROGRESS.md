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
