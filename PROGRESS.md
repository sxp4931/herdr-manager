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

## Milestone 06 — Collect tmux agents and optional loop manifests

- Status: complete
- Date (UTC): 2026-09-30
- Preceding HEAD: `4572670` `feat: collect git worktree activity`
- Commit message: `feat: observe tmux sessions and loop manifests`
- Commands and results:
  - `npm run test:unit -- tests/unit/identity.test.ts` — exit 0. 5 passed, 0 failed, 0 skipped.
  - `npm run test:integration -- tests/integration/tmux.test.ts` — exit 0. 1 passed, 0 failed, 0 skipped.
  - `npm run check` — exit 0. Unit 17 passed. Python 1 passed. Integration 18 passed.
- Results: a private `tmux -L chhaya-dashboard-test-<random>` server with synthetic Node scripts named claude, codex, and grok produced three agent rows and omitted the shell pane. Each process-only row has status `unknown` and a null loop. A fresh `.herdr-dashboard/run.json` whose pid, start ticks, provider, and cwd match identifies `goal`/`running` from the manifest; a 31s-old manifest and a manifest whose start ticks differ by one do not. The adapter argv contains `list-panes` and never `send-keys`, `capture-pane`, `kill-session`, `kill-server`, or `new-session`. Worktree bytes were unchanged across collection. A missing private server reports `tmux_server_missing` with no sessions. A missing tmux binary reports `tmux_missing` without a spawn. No live user tmux server, no real Claude/Codex/Grok CLI, and no live account data. `LANG=C.UTF-8` is required because tmux 3.5a rewrites tab separators to underscores under the C locale.

## Milestone 07 — Implement the Linux herdr read adapter

- Status: complete
- Date (UTC): 2026-09-30
- Preceding HEAD: `808570c` `feat: observe tmux sessions and loop manifests`
- Commit message: `feat: reuse herdr read model on Linux`
- Commands and results:
  - `npm run test:integration -- tests/integration/herdr.test.ts` — exit 0. 8 passed, 0 failed, 0 skipped.
  - `npm run check` — exit 0. Unit 17 passed. Python 1 passed. Integration 26 passed.
- Results: a private Unix socket accepted only `agent.list` and `session.snapshot`. The agent list kept Claude, Codex, Grok, and an unknown `opencode` provider, dropped an empty agent and an empty pane id, and retained label, cwd, pid, and `stateChangeSeq`. An unrecognized status became `unknown`. Split frames, a coalesced out-of-order preface, a numeric id, and `"error": null` parsed. An oversized frame was rejected without a retry. A frame without a newline timed out inside 3.5 seconds and did not wait a second full budget. One dropped connection was retried. A removed pane disappeared, a same occupant kept `enteredAt`, and a replaced session identity reset it. After the socket was removed, health was `stale` and the previous sessions stayed. Protocol 16 is `protocol_older` / `unsupported` and protocol 18 is `protocol_newer` while both still return agents. Herdr and tmux rows merged only when provider, pid, and cwd agreed. No live herdr daemon was started. The installed `herdr` binary is absent; see `BLOCKERS.md` B-01.

## Milestone 08 — Build the PTY emulator and fail-closed diagnostic state machine

- Status: complete
- Date (UTC): 2026-09-30
- Preceding HEAD: `d74d376` `feat: reuse herdr read model on Linux`
- Commit message: `feat: add safe CLI quota probe transport`
- Commands and results:
  - `npm run test:python` — exit 0. 27 passed, 0 failed, 0 skipped.
  - `npm run test:integration -- tests/integration/probe-boundary.test.ts` — exit 0. 16 passed, 0 failed, 0 skipped. A slow fake CLI with `--deadline-ms 2000` finished in 2070ms. Its `sleep` child was reaped.
  - `npm run check` — exit 0. Unit 17 passed. Python 27 passed. Integration 34 passed.
  - `node scripts/check-policy.mjs` — exit 0. `policy ok`.
- Results: `tests/helpers/fake-cli.py` ran on a real PTY. `tty-check` was `1` and the JSON `isatty` field was true. After an ANSI clear, the in-memory screen was `Session  10% used` and `Weekly  20% used`; probe stdout was one JSON object, stderr was the reason code, and neither contained that screen or `SYNTHETIC_SECRET_SENTINEL`. Trust, redemption (including a prompt on the same screen), login, and model traps left an empty keystroke file. Version support is exactly `fixture-1.0.0`; `99.0.0` sent nothing. A 60000ms request was clamped to 20000ms. The 2000ms hang stayed under 8s and under 22s, with no orphan child. Cancellation killed the probe process group and left a sibling `sleep` outside that group running. A held `HERDR_PROBE_LOCK` returned `probe_busy` without creating a pid file. Claude, Codex, and Grok profiles return `profile_unsafe` and were not executed. No live CLI and no account quota was read.

## Milestone 09 — Parse provider quotas and Codex reset inventory

- Status: complete
- Date (UTC): 2026-09-30
- Preceding HEAD: `ae2bc5e` `feat: add safe CLI quota probe transport`
- Commit message: `feat: read CLI subscription quotas and reset inventory`
- Commands and results:
  - `npm run test:unit -- tests/unit/quota.test.ts` — exit 0. 6 passed, 0 failed, 0 skipped.
  - `npm run test:python` — exit 0. 29 passed, 0 failed, 0 skipped.
  - `npm run test:integration -- tests/integration/collector.test.ts` — exit 0. 3 passed, 0 failed, 0 skipped. Each fake CLI finished well under 8 seconds.
  - `npm run check` — exit 0. Unit 23 passed. Python 29 passed. Integration 37 passed.
  - `node scripts/check-policy.mjs` — exit 0. `policy ok`.
- Results: Claude, Codex, and Grok fixture profiles ran on real PTYs through `fake-claude.py`, `fake-codex.py`, and `fake-grok.py`. Daily screens match milestone 02: Claude 10/20, Codex 35 used from `65% left` and 25 used from `75% left`, Grok weekly 15 with 5h `not_applicable`. Codex keystrokes are `/status`, Escape, `/usage`, with no redeem, apply, or confirm confirmation. Quantity and expiry are kept; `earnedAt` stays null. A `none` inventory is a known empty array. A redeem screen after `/status` keeps the 5h reading, sets banked status `unknown`, and does not type a confirmation. Ambiguous `Sun Nov 1, 2026 1:30 AM`, the March 8 2026 2:30 AM gap, weekday-only times, and malformed dates leave `resetsAt` null. `Nov 1, 2026 3:30 AM` is `2026-11-01T08:30:00.000Z`. Probe stdout has no screen text. Live `claude`, `codex`, and `grok` were not started; B-02, B-03, and B-04 record that external gap. B-01 stays open.
