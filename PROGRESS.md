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

## Milestone 10 — Schedule collectors and expose immutable HTTP snapshots

- Status: complete
- Date (UTC): 2026-09-30
- Preceding HEAD: `ee5c68a` `feat: read CLI subscription quotas and reset inventory` (`ee5c68a7fbb7cc5630abbd0d2949d93585e97e6d`)
- Commit message: `feat: serve scheduled read-only dashboard snapshots`
- Commands and results:
  - `npm run test:unit -- tests/unit/scheduler.test.ts` — exit 0. 12 passed, 0 failed, 0 skipped. Re-run after the listener change.
  - `npm run test:integration -- tests/integration/http.test.ts` — exit 0 on the scheduler before the listener change. 4 passed, 0 failed, 0 skipped. The same file passed again inside the post-change `npm run check` below.
  - `npm run check` — exit 0 on the committed tree. Lint and typecheck passed. Unit 35 passed. Python 29 passed. Build passed. Integration 40 passed, including `tests/integration/http.test.ts` (4 passed; SSE reconnect about 10.1 seconds). Zero failures, zero skips.
  - `node scripts/check-policy.mjs` — exit 0. `policy ok`. An earlier scan rejected `Set.delete` in the scheduler as a mutating route registration. Listeners are now removed with `splice`, and loop sleep is tracked with flags. The scan still rejects `.post(`, `.put(`, `.patch(`, and `.delete(`.
- Results: A frozen clock drives the copied session cadence of 10 seconds and the git cadence of 30 seconds. Changing the config after construction does not shorten those sleeps. Quota collection is single-flight across Claude, Codex, and Grok. A failed probe keeps the original `sampledAt` and `lastSuccessAt`. An older sample does not replace a newer one. Quota, session, and git samples stay fresh at exactly 10 minutes, 30 seconds, and 90 seconds, and become stale one millisecond later without advancing the snapshot sequence. `GET /api/snapshot` returns while a collector is still blocked. `stop()` finishes in under 500 milliseconds and further clock advances do not collect. Foreign Host and Origin return 403, POST returns 405, an unknown API route returns 404, the SSE sequence grows, and a reconnect receives the latest snapshot. Health stays 200 when optional providers are broken. Fixture mode serves the synthetic daily scenario with fixture provenance and does not launch host CLIs. Live quota probes stay `profile_unsafe` and are not spawned. B-01, B-02, B-03, and B-04 stay open. The existing user tmux server was left running.

## Milestone 11 — Implement capacity and expiry alerts

- Status: complete
- Date (UTC): 2026-09-30
- Preceding HEAD: `c13d6ab` `feat: serve scheduled read-only dashboard snapshots` (`c13d6aba145d9de593d28bc51d19259da31e00e0`)
- Commit message: `feat: surface idle capacity and reset expiry alerts`
- Commands and results:
  - `npm run test:unit -- tests/unit/alerts.test.ts tests/unit/scheduler.test.ts` — exit 0. Alert rules 11 passed. Scheduler 12 passed. 0 failed, 0 skipped.
  - `npm run check` — exit 0. Lint and typecheck passed. Unit 46 passed, including `tests/unit/alerts.test.ts` (11 passed). Python 29 passed. Build passed. Integration 40 passed, including `tests/integration/http.test.ts` (4 passed). Zero failures, zero skips.
  - `node scripts/check-policy.mjs` — exit 0. `policy ok`.
- Results: The fixed daily scenario emits weekly-underused alerts for Claude, Codex, and Grok, one expiring Codex reset, and one unusable Codex reset. It does not emit an idle alert. Exactly 48 hours does not trigger weekly or banked-expiring alerts; one millisecond under 48 hours does. Weekly remaining of 40% triggers and 39% does not. Five-hour remaining of 20% can idle and 19% cannot. A weekly remainder of zero suppresses both the underused and idle alerts. The idle alert appears only after ten continuous minutes of fresh herdr and tmux coverage, keeps its original `createdAt` while the condition holds, and starts a new ledger entry if the condition returns. Grok's not-applicable 5h window never produces an idle alert. Unknown tmux activity suppresses the idle alert. Stale quota, missing or stale session sources, unknown reset times, expired resets, and fixture provenance in live mode suppress capacity alerts. A degraded passive server reports `source_problem` for disabled probes and a missing herdr socket, and it does not invent capacity. B-01, B-02, B-03, and B-04 stay open. The existing user tmux server was left running.

## Milestone 12 — Build quota cards, banked inventory, themes, and source status

- Status: complete
- Date (UTC): 2026-09-30
- Preceding HEAD: `c3d829f` `feat: surface idle capacity and reset expiry alerts` (`c3d829f60b94058925c6dd84b032d9f843f45234`)
- Commit message: `feat: display provider quota and banked reset cards`
- Commands and results:
  - `npm run test:unit -- tests/unit/format.test.ts tests/unit/database-path.test.ts` — exit 0. Format text 4 passed. Database path 3 passed. 0 failed, 0 skipped.
  - `npm run check` — exit 0 at 2026-09-30T05:14:38Z. Lint and typecheck passed. Unit 53 passed. Python 29 passed. Build passed. Integration 40 passed. Zero failures, zero skips.
  - `npm run test:e2e -- tests/e2e/dashboard.spec.ts tests/e2e/staleness.spec.ts` — exit 0. 8 passed in Chromium headless against the built fixture server. 0 failed, 0 skipped.
  - `node scripts/check-policy.mjs` — exit 0. `policy ok`.
- Results: The production page shows Claude, Codex, and Grok cards with used/left text and meters. Countdowns use the snapshot `generatedAt`, so the daily fixture reads 4 hours, 36 hours, 37 hours, and 47 hours against `2026-09-29T20:00:00.000Z`, `2026-10-01T04:00:00.000Z`, `2026-10-01T05:00:00.000Z`, and `2026-10-01T15:00:00.000Z`. Codex lists `codex-reset-expiring` and `codex-reset-unusable`, expiry `2026-09-30T16:00:00.000Z` (24 hours), and the reported reason `redeemable only after expiry`. Fixture mode shows “Demo data.” Grok’s 5h window says “Not applicable” and has no meter. Missing quota says “Unknown” and draws no zero meter. A stale Claude sample stays labeled Stale, uses a stale meter, and shows the original `2026-09-29T15:45:00.000Z`. Disabled probes say “Disabled” and “Probes disabled,” with no fresh meter. Light and dark themes change the paper and ink colors, an explicit choice survives reload, and an unset choice follows `prefers-color-scheme`. The browser recorded no off-loopback requests and no uncaught exceptions. The only control is the theme button. Reference font binaries were not copied because the reference tree has no license notice; system stacks are recorded in `docs/DECISIONS.md`. `HERDR_STATE_DIR` holds the Playwright database, so the run did not create `.local/dashboard.sqlite`. B-01, B-02, B-03, and B-04 stay open. The existing user tmux server was left running.

## Milestone 13 — Build session triage, loop and worktree details, and alert views

- Status: complete
- Date (UTC): 2026-09-30
- Preceding HEAD: `4413da3` `feat: display provider quota and banked reset cards` (`4413da3a54880043d9a02134ca23985ff9e97bbc`)
- Commit message: `feat: show agent triage and git work details`
- Commands and results:
  - `npm run build` — exit 0. Vite built `apps/web/dist` (108 modules) after the filter accessible-name change.
  - `npm run check` — exit 0 at 2026-09-30T05:24:20Z. Lint and typecheck passed. Unit 56 passed, including `tests/unit/sessions.test.ts` (3 passed) and `tests/unit/format.test.ts` (4 passed). Python 29 passed. Build passed. Integration 40 passed. Zero failures, zero skips.
  - `npm run test:e2e -- tests/e2e/dashboard.spec.ts tests/e2e/keyboard.spec.ts tests/e2e/staleness.spec.ts` — exit 0. 11 passed in Chromium headless against the built fixture server. 0 failed, 0 skipped. An earlier run of the same command exited 1 because `getByLabel("Status")` also matched the Source status region. The selects now expose exact accessible names, and this rerun passed.
  - `node scripts/check-policy.mjs` — exit 0. `policy ok`.
- Results: The daily fixture sorts working agents ahead of done and unknown. Search for `goal-runner` hides the other rows. Expanding the goal row shows `Loop goal / running. Source manifest.`, iteration 2, and branch `feature/demo`. Expanding `daily-claude-worker` shows staged 1, modified 1, untracked 1, conflicted 0, SHAs `bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb` and `aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa`, and fresh worktree health. The process-only Codex row stays `Unknown` and reports `Loop unknown / unknown. Source process.` with no mapped worktree. Dwell uses snapshot `generatedAt` (`20 minutes` for the Claude worker). The hostile label renders as text and creates no image. A manual clock harness emits `window_open_idle:claude:five_hour:all` after ten minutes and clears it after a working tick while the Codex idle alert remains. Source problems stay under Source status. Capacity alerts on the live fixture page come from `GET /api/snapshot`. Desktop 1440×900 keeps both quota windows and the first agent row inside the viewport. Phone width still stacks the cards. No start, stop, approve, redeem, or refresh control is present. The run did not create `.local/dashboard.sqlite`. B-01, B-02, B-03, and B-04 stay open. The existing user tmux server was left running.

## Milestone 14 — Verify read-only security, degraded operation, and browser resilience

- Status: complete
- Date (UTC): 2026-09-30
- Preceding HEAD: `7f20475` `feat: show agent triage and git work details` (`7f20475199955fb5f081609165fbf74cb2ca41c1`)
- Commit message: `test: verify safe degraded dashboard operation`
- Commands and results:
  - `npm run check` — exit 0. Lint and typecheck passed. Unit 56 passed. Python 29 passed. Build passed. Integration 46 passed, including `tests/integration/read-only-audit.test.ts` (6 passed). Zero failures, zero skips.
  - `npm run test:e2e` — exit 0. 15 passed in Chromium headless against the built fixture server. 0 failed, 0 skipped. An earlier full run exited 1 because the keyboard test read agent buttons before the snapshot render; it now waits for `Show details for daily-claude-worker`, and this rerun passed.
  - `node scripts/check-policy.mjs` — exit 0. `policy ok`.
- Results: POST, PUT, PATCH, DELETE, and TRACE on `/` and every exported read-only route return 405 with `Allow: GET`. Responses, the fixture SQLite file, and server stderr do not contain `SYNTHETIC_SECRET_SENTINEL` or a raw screen. A real git commit whose subject contains that sentinel, a URL password, a script tag, a traversal path, and a control character is stored as redacted text. The git adapter’s observed commands stay in `rev-parse`, `status`, `symbolic-ref`, `log`, `worktree list`, and `--version`. A `log` that does not finish becomes worktree health `timeout` in about 8 seconds. Tmux is asked only for `-V` and `list-panes` on an explicit missing socket. A herdr socket that drops the frame reports a non-ok source and only sends `agent.list` and `session.snapshot`. A usage PTY that ignores a 100ms deadline returns `timeout`, sends no keys, and its process group is reaped. The browser keeps `document.documentElement.scrollWidth <= innerWidth` at 1440×900 and 390×844. Hostile script, traversal, and URL text stay text: no image, no inline script, and no link. A closed event stream reconnects and shows the updated row. Reduced motion computes to `0s`, a rejected font load still shows the heading in a sans-serif stack, and the theme control’s focus outline is at least 3px. Missing, disabled, and stale snapshots leave the page usable. B-01, B-02, B-03, and B-04 stay open. The existing user tmux server was left running.

## Milestone 15 — Write operations, provider doctor, and offline CI

- Status: complete
- Date (UTC): 2026-09-30
- Preceding HEAD: `332768c` `test: verify safe degraded dashboard operation` (`332768cb6a539b4a2140ec5d1c818354808bfdc8`)
- Commit message: `docs: add Linux operations and offline verification CI`
- Commands and results:
  - `node scripts/probe-doctor.mjs --json` — exit 0. Three providers, each `liveProbe` false. Present binaries are `present` / `not_requested`. `executedCount` 0.
  - `node scripts/probe-doctor.mjs --live` — exit 0. Three providers, each `liveProbe` false. Present binaries are `profile_unsafe` / `refused` with reason `startup hooks and MCP are not proven inert`. `executedCount` 0. No PTY was opened.
  - `npm run test:unit -- tests/unit/ci-policy.test.ts` — exit 0. 1 passed, 0 failed, 0 skipped.
  - `npm run test:integration -- tests/integration/probe-boundary.test.ts` — exit 0. 17 passed, 0 failed, 0 skipped. An isolated `PATH` of trap binaries named `claude`, `codex`, and `grok` stayed unexecuted for both `--json` and `--live`. Stdout omitted the synthetic env sentinel and home path.
  - `npm run check` — exit 0 at 2026-09-30T05:40:54Z. Lint and typecheck passed. Unit 57 passed. Python 29 passed. Build passed. Integration 47 passed. Zero failures, zero skips.
  - `npm run test:e2e` — exit 0. 15 passed in Chromium headless against the built fixture server. 0 failed, 0 skipped.
  - `node scripts/check-policy.mjs` — exit 0. `policy ok`.
  - `node scripts/check-ci.mjs` — exit 0. JSON `hostedActionsExecuted` false, `runsOn` `ubuntu-22.04`, Node `22.23.2`, Python `3.13.7`, permissions `contents: read`, `ok` true. This machine did not run hosted Actions.
- Results: README lists `npm ci`, the Python venv, `npm run build`, `npm start`, the local config copy, and passive, live, and fixture modes. Ctrl+C maps to the existing SIGINT and SIGTERM shutdown. The doctor prints status codes and does not launch a usage PTY. `.github/workflows/ci.yml` names the hosted pins and the root scripts `check:policy`, `check`, and `test:e2e`. B-01, B-02, B-03, and B-04 stay open. The run did not create `.local/dashboard.sqlite`. The existing user tmux server was left running.

## Milestone 16 — Deliver independent reproducible evidence

- Status: complete
- Date (UTC): 2026-09-30
- Preceding HEAD: `c7dce81` `docs: add Linux operations and offline verification CI` (`c7dce81d3bd37b79d6992a0ce6010aa86c595d80`)
- Commit message: `chore: finalize reproducible dashboard verification`
- Commands and results:
  - `npm run test:unit -- tests/unit/database-path.test.ts` — exit 0. 4 passed, 0 failed, 0 skipped. Fixture mode throws unless `HERDR_ALLOW_NETWORK=0`.
  - `npm run test:integration -- tests/integration/smoke.test.ts` — exit 0. 2 passed, 0 failed, 0 skipped. The smoke script read a real fixture server, including the 15 second SSE heartbeat, and wrote evidence with `ok` true and `skippedTests` 0.
  - `npm run test:integration -- tests/integration/http.test.ts tests/integration/read-only-audit.test.ts` — exit 0. 10 passed, 0 failed, 0 skipped.
  - `bash scripts/verify.sh` — exit 0 at 2026-09-30T05:48:22Z and again at 2026-09-30T05:50:14Z. Each last line was `VERIFY herdr-dashboard PASS`. Inside a run: `npm ci` exit 0, `pip check` found no broken requirements, `check:policy` printed `policy ok`, `npm run check` exit 0 (unit 58, Python 29 OK, integration 49, zero skips), `npm run test:e2e` exit 0 (15 passed), smoke printed `smoke ok`, artifact policy printed `policy ok`.
- Evidence from `.artifacts/verify/smoke.json` on that run: `ok` true, `skippedTests` 0, and these checks passed: health, providers, banked-inventory, provenance, sessions, worktrees, alerts, unknown-api, mutations, hostile-host, headers, page, sse.

| Surface | Evidence |
| --- | --- |
| Fake CLI PTY | Python probe tests and `tests/integration/collector.test.ts` ran inside `npm run check` |
| Herdr Unix socket | `tests/integration/herdr.test.ts` ran inside `npm run check` |
| Git worktrees | `tests/integration/git.test.ts` ran inside `npm run check` |
| Production page | Playwright 15 passed, and smoke read `/` plus the fixture snapshot on `127.0.0.1:14317` |

- Results: The verifier uses a fresh `HERDR_STATE_DIR` and does not reuse port 14317 when something is already listening. Fixture mode refuses to start unless `HERDR_ALLOW_NETWORK=0`. B-01, B-02, B-03, and B-04 stay open. The run did not create `.local/dashboard.sqlite`. The existing user tmux server was left running. A second pair of `bash scripts/verify.sh` runs is executed after this commit so the final tree stays clean.

## Correction — Age out omitted git worktrees

- Status: complete
- Date (UTC): 2026-09-30
- Preceding HEAD: `9724ca4` `chore: finalize reproducible dashboard verification` (`9724ca4d733ff2c5a676c24bd79dd79be856fec4`)
- Commit message: `fix: age out git worktrees missing for 24 hours`
- Commands and results:
  - `npm run test:integration -- tests/integration/sqlite.test.ts` — exit 0. 5 passed, 0 failed, 0 skipped. The new case stores two fixture worktrees, omits one on the next `applyGit`, keeps it at exactly 24 hours, and drops it once the clock passes that mark. The worktree still present in the collect remains.
  - `npm run check:policy` — exit 0. `policy ok`.
  - `npm run check` — exit 0 at 2026-09-30T06:15:25Z. Lint and typecheck passed. Unit 58 passed. Python 29 passed. Build passed. Integration 50 passed. Zero failures, zero skips.
- Results: `applyGit` now removes a `git_cache` row that a later full collect does not include once its stored `observedAt` is older than 24 hours. B-01, B-02, B-03, and B-04 stay open. The existing user tmux server was left running.
