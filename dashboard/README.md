# herdr dashboard

Read-only Linux dashboard for subscription quota, herdr and tmux sessions, and git worktrees. It binds to loopback and serves the built page from this repository.

## Runtime

- Node `22.23.2`
- npm `10.9.3` (`packageManager` in `package.json`, via Corepack)
- Python 3.13 for the PTY helper. This machine uses Python `3.13.5`, recorded in `docs/DECISIONS.md`. The workflow file names Python `3.13.7` for a hosted Ubuntu 22.04 runner.
- `pyte==0.8.2` and `wcwidth==0.2.13` from `probes/requirements.txt`

## Install

```bash
npm ci
python3 -m venv .venv
.venv/bin/python -m pip install -r probes/requirements.txt
npm exec playwright install chromium
```

`npm ci` installs the committed lockfile. Playwright installs its Chromium build. These commands do not install operating-system packages.

## Build and start

```bash
npm run build
cp config/dashboard.example.json config/dashboard.local.json
npm start -- --config config/dashboard.local.json
```

`npm start` runs `node apps/server/dist/main.js`. The default bind is `127.0.0.1:4317`. Any other host is refused. Flags are `--host`, `--port`, `--config`, `--database`, and `--fixture`.

`config/dashboard.local.json` is gitignored. The example config is mode `passive`, with `quotaProbesEnabled` false, empty `repositoryRoots`, and null `herdrSocket` and `tmuxSocket`. Poll intervals are 10 seconds for sessions, 30 seconds for git, and 300 seconds for quota.

Stop the process with Ctrl+C. `SIGINT` and `SIGTERM` both stop the scheduler, close SQLite, and close the HTTP server.

Without `--database` or `HERDR_STATE_DIR`, the database file is `.local/dashboard.sqlite`. Set `HERDR_STATE_DIR` to a private directory when you want that file outside the repository. `.local/` is gitignored.

## Modes

### Passive

The example config. Quota probes stay off. Git, tmux, and herdr observations run only for the absolute roots and sockets written in the local config. A missing source stays visible as source health.

### Live

Set `"mode": "live"` and `"quotaProbesEnabled": true`. Live mode requires probes to be enabled. The running server still reports each provider as `profile_unsafe` and does not start `claude`, `codex`, or `grok`. See `docs/OPERATIONS.md` and `BLOCKERS.md` (B-02, B-03, B-04).

### Fixture

The synthetic catalog. `HERDR_FIXTURE=1` selects fixture mode. `--fixture` refuses to start unless that variable is set. Fixture mode also refuses to start unless `HERDR_ALLOW_NETWORK=0`. The scheduler clock is `2026-09-29T16:00:00.000Z`. Verification sets `HERDR_FIXTURE_NOW` to that same instant.

```bash
HERDR_FIXTURE=1 \
HERDR_ALLOW_NETWORK=0 \
HERDR_FIXTURE_NOW=2026-09-29T16:00:00.000Z \
HERDR_STATE_DIR=/path/to/private/state \
npm start -- --fixture --host 127.0.0.1 --port 4317
```

Fixture mode does not read host git, tmux, herdr, or a usage PTY. The page labels the catalog as demo data.

## Checks

```bash
node scripts/preflight.mjs --json
node scripts/preflight.mjs --require-core
node scripts/probe-doctor.mjs --json
npm run check:policy
npm run check
npm run test:e2e
```

`node scripts/preflight.mjs --json` prints `coreReady`, `platform`, Node, Python, `node:sqlite`, and whether `claude`, `codex`, `grok`, `tmux`, and `herdr` are on `PATH`. Optional CLIs do not change `coreReady`. `--require-core` also requires `.venv` `pyte` and `wcwidth`, plus Playwright Chromium, and exits 1 when one of those is missing.

`node scripts/probe-doctor.mjs --json` exits 0 and prints three provider entries when an optional CLI is missing. It does not open a PTY. `liveProbe` is false. A binary that is only present on `PATH` is status `present` with diagnostic `not_requested`.

`node scripts/probe-doctor.mjs --live` also exits 0 with three entries and `liveProbe` false. A present binary is status `profile_unsafe`, diagnostic `refused`, because startup hooks and MCP are not proven inert. The diagnostic argument allowlist is `--version` and `--help`, and that allowlist is not executed. The report contains status codes only.

`node scripts/check-ci.mjs` reads `.github/workflows/ci.yml` and prints JSON with `hostedActionsExecuted` false. `npm run check:policy` runs that same check. Reading the workflow file is a local machine check.

`npm run check` runs lint, typecheck, unit tests, Python tests, the production build, and integration tests. `npm run test:e2e` runs Playwright Chromium headless against the built page on `127.0.0.1:14318`.

## Further reading

- `docs/OPERATIONS.md` — profiles, banked inventory, loop manifests, private temp directories, backup and retention
- `docs/CLI_PROFILES.md` — probe commands and fixture profiles
- `docs/SECURITY.md` — storage, redaction, HTTP, and command limits
- `BLOCKERS.md` — open external capability gaps
