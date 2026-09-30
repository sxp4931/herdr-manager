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
