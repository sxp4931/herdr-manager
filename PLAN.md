# Plan A — herdr dashboard for Linux

## 1. Execution contract

Build a new, self-contained `herdr-dashboard` repository. This is a daily localhost dashboard for Shyam Pandya: Claude Code and Codex subscription window/weekly quota, Grok weekly quota, visible Codex earned/banked resets and their expiry, agent activity, git work, and actionable information alerts. The execution target is Grok CLI `grok-4.7-build-fast` with xhigh reasoning in `/goal` mode on Ubuntu. Build portable TypeScript/Python software; do not build or invoke Swift, Xcode, AppKit, Electron, or a macOS toolchain.

Non-goals: cloud hosting, deployment, remote access, vendor API billing estimates, inferred quotas from token totals, buying credits, redeeming resets, prompting agents, approvals, stopping agents, spawning coding loops, editing monitored worktrees, desktop notifications, multi-user accounts, and an MCP wire server. V1 has no agent action buttons or write endpoints; do not add an action feature flag that later enables them. Read-only collection is separate from sending diagnostic slash commands to a new, dashboard-owned CLI probe.

Hard rules for every round:

1. Work only in the new repository on `feat/herdr-dashboard-v1`. Treat the supplied reference repositories as read-only. Never push, create a PR, merge, deploy, spend money, install an agent subscription, or use a real API key. Package and Chromium downloads are the only necessary installation network traffic. Do not perform system package installation unattended.
2. Never read credential files, copy authentication tokens, scrape account websites, reverse-engineer private quota HTTP endpoints, or print/commit secrets. The installed CLI may use its own existing login internally. Remove API-key environment variables from its child environment so API-billed authentication cannot be selected accidentally. Do not login, logout, update, or change account settings automatically.
3. Use `spawn`/`execFile` with argument arrays and `shell:false`; never interpolate a path, branch, provider, or pane identifier into a shell string. Keep child commands behind a narrow allowlist and time/output limits. Git observations must set `GIT_OPTIONAL_LOCKS=0` and `GIT_TERMINAL_PROMPT=0`.
4. Never send input to an existing user/herdr/tmux pane. A usage probe gets a new, owned PTY process group in an empty private directory. It must not resume a conversation, submit prose, accept workspace trust, answer a prompt, redeem anything, or launch a model turn. Fail closed if the known screen/command profile is absent.
5. Create `PROGRESS.md`, `BLOCKERS.md`, and `docs/DECISIONS.md` in milestone 01. Each progress entry records milestone, UTC date, commands, exit codes, concise sanitized results, and the milestone commit. Record fixtures as fixtures; never call mocked verification a live-account success.
6. Complete milestones in order. Write relevant tests before the implementation that they exercise. Run the common gate and the milestone-specific acceptance commands. Fix failures before continuing. Stage named paths only, inspect `git diff --cached --check` and the staged diff, then commit each milestone with the supplied message. Progress stores that exact milestone commit message and the preceding HEAD; the resulting commit hash is resolved from `git log` by the reviewer, avoiding a self-referential hash edit after commit. If the host has no git identity, use a repo-local synthetic identity `Chhaya Build Agent <build-agent@example.invalid>`; do not alter global git config.
7. Unavailable installed CLIs, accounts, herdr, or tmux are supported degraded states, not reasons to abandon the build. Missing Node/Python/browser runtime or failed tests are actual verification blockers; record them and do not claim completion. Do not weaken tests, skip required cases, or replace the real PTY/socket/git integration with canned HTTP JSON.

### Reference grounding and decisions

Paths below are relative to the provided reference root (initially `../refs`); support an explicit `CHHAYA_REFS_DIR` for evidence extraction only. Read these files before implementation; copy only permitted assets and synthetic schemas, never configuration directories or private data.

| Reference inspected | Pattern to carry into this repository |
| --- | --- |
| `herdr-manager/README.md` | Product is named **Shepherd**, a macOS companion to herdr; verified baseline herdr 0.7.5 / wire protocol 17. This web app is a sibling client of the same herdr socket, not a wrapper around the Swift executable. |
| `herdr-manager/Sources/HerdrManagerCore/Domain/Types.swift` | `AgentID` preserves workspace/pane identity, `AgentStatus` is idle/working/blocked/done/unknown, `stateChangeSeq`, session identity, cwd, last output, and dwell time are separate concepts. Unknown kinds survive decoding. |
| `herdr-manager/Sources/HerdrManagerCore/Adapter/HerdrAdapter.swift`, `Adapter/NDJSONClient.swift` | `agent.list` is authoritative; merge `session.snapshot` labels, tolerate added fields, bound NDJSON, match request IDs. Wire requests have `id`, `method`, `params`; they are not necessarily JSON-RPC 2.0 envelopes. |
| `herdr-manager/Sources/herdr-manager-mcp/HerdrManagerMCP.swift` | Reuse read concepts `herd.overview`, `agent.list`, and `agent.inspect` as internal service functions. Exclude `agent.answer`, `agent.say`, `agent.stop`, and `session.spawn`. |
| `herdr-manager/Sources/HerdrManagerCore/Usage/TokenMeterTypes.swift`, `TokenMeterReader.swift` | Existing hour/day/week/month **token estimates** do not measure a 5-hour subscription limit. Do not reuse their usage values for quota cards. |
| `FinanceVisibilityApp/README.md`, `finance_analyzer/web/server.py` | Local backend serves a built browser UI, binds loopback, and keeps SQLite data local. Adopt this operating pattern, not the finance app's glass styling. |
| `project-relay/README.md`, `docs/PRIVACY_MODEL.md` | Local-first boundaries, closed diagnostic event vocabulary, and confirmation before external actions. V1 removes external actions entirely. |
| `chhaya-digital-website/chhaya-digital/css/styles.css`, `css/fonts.css` | Paper/ink colors, flat borders, readable tables, Source Serif 4 / Schibsted Grotesk / IBM Plex Mono, dark theme, reduced motion. Use the actual tokens and font assets with notices. |
| `Bean-Brawl/AGENTS.md`, `rakazo/AGENTS.md` | Offline deterministic tests and explicit statement of what headless evidence proves. Do not import their native/desktop/release workflows. |

Record source repository HEAD hashes and relevant relative paths in `docs/REFERENCE_PATTERNS.md`. Do not copy reference `AGENTS.md` verbatim into the new repo; write the above rules into the new `AGENTS.md`.

Primary documentation checked while planning: [Codex developer commands](https://learn.chatgpt.com/docs/developer-commands?surface=cli) documents `/status` and `/usage`; the latter can expose reset redemption actions, so never select an unverified action. [Grok CLI reference](https://docs.x.ai/build/cli/reference) and [Grok commands](https://docs.x.ai/build/modes-and-commands) document the interactive CLI and `/usage`. [Claude interactive mode](https://code.claude.com/docs/en/interactive-mode) describes TUI behavior. The owner specifically identifies Claude `/usage`, Codex `/status` plus `/usage`, and Grok `/usage` as quota sources. Installed versions and screen shapes must be verified at runtime. No official noninteractive subscription-quota flag was established by this planning pass; do not invent one or use a model prompt such as `claude -p '/usage'`.

## 2. Architecture and pinned stack

### Stack

Use npm workspaces, ESM, strict TypeScript, React + Vite, a Node HTTP server, Node's built-in SQLite, and a Python PTY helper. No Docker, Redis, paid service, native npm addon, UI component framework, or runtime font CDN.

| Component | Exact pin / contract |
| --- | --- |
| Node / npm | Node `22.23.2`; npm `10.9.3`; `.nvmrc`, `engines`, `packageManager`; compatible newer Node 22 patch allowed only with recorded decision and full gate |
| TypeScript | `5.9.3` |
| React / react-dom | `19.2.3` each |
| Vite / React plugin | `8.3.0` / `6.1.1` |
| Zod | `4.4.3` |
| esbuild | `0.28.2` (bundle production Node entry and shared contracts) |
| Vitest | `4.1.11` |
| Playwright test | `1.63.0`, Chromium only, headless |
| ESLint / @eslint/js | `9.39.5` each |
| typescript-eslint | `8.68.0` |
| @types/node / @types/react / @types/react-dom | `22.16.5` / `19.2.18` / `19.2.5` |
| Python | `3.13.7` preferred; stdlib APIs supported on Python 3.10–3.13; record actual patch, no OS replacement |
| Python terminal emulator | `pyte==0.8.2`, `wcwidth==0.2.13`, isolated `.venv` |
| Persistence | `node:sqlite` `DatabaseSync`, WAL, foreign keys, bounded writes, no npm SQLite dependency |
| tmux / git | Use installed `tmux` 3.x and git 2.39+; detect exact version. No unattended installation required. |

The npm pins mostly match concrete reference manifests/locks, with TypeScript 5.9.3 from Bean-Brawl rather than adopting rakazo's newer compiler. Registry checks from this planning environment timed out; milestone 01 must establish resolvability and compatibility, not assume the plan was installed/tested. If a pin is unavailable or peers conflict, try once with registry metadata, record evidence in `BLOCKERS.md`, choose the nearest compatible published non-prerelease patch in the same major, update all exact pins and lockfile, and rerun the gate. Never use `--force`, `--legacy-peer-deps`, `latest`, `^`, or `~`. Transitives are fixed by committed lockfile. Alternative: FastAPI + React would also fit the finance reference; Node avoids a second web framework and uses the same TypeScript contracts on both sides.

### Processes and layout

All internal npm workspaces have version0.1.0 and exact internal dependencies0.1.0; npm links matching local workspaces, so do not use pnpm-only `workspace:*` dependency syntax. Shared contracts export TypeScript source for Vite/Vitest/esbuild. Typecheck uses noEmit across explicit workspace source includes (no app-only rootDir restriction); Vitest aliases workspace imports to source. Bundle the server with pinned esbuild (platform=node, format=esm, target=node22, bundle=true, node built-ins external), including contract/Zod implementation, to the exact `apps/server/dist/main.js` path. The production Node entry must never import a workspace TypeScript source from node_modules. Server build first, web Vite build second.

One production process listens only on `127.0.0.1:4317`, serves `apps/web/dist`, schedules collectors, reads/writes its own SQLite, and streams sanitized snapshots. Vite dev binds `127.0.0.1:4318` with `/api` proxy to 4317. Python helper is spawned per bounded probe; no resident unbounded shell. API never blocks waiting on a collector. Browser GET refresh reads cache; collection has an independent cadence.

```text
herdr-dashboard/
  PLAN.md GOAL.md AGENTS.md README.md PROGRESS.md BLOCKERS.md
  package.json package-lock.json .nvmrc .npmrc .gitignore
  tsconfig.base.json eslint.config.mjs
  config/dashboard.example.json
  apps/server/
    package.json tsconfig.json src/
      main.ts http.ts security.ts config.ts scheduler.ts
      storage/{database.ts,migrations/001.sql,repository.ts}
      services/{snapshot.ts,sessions.ts,quota.ts,alerts.ts,redaction.ts}
      adapters/{command-runner.ts,git.ts,tmux.ts,herdr.ts,quota-probe.ts}
  apps/web/
    package.json tsconfig.json vite.config.ts index.html src/
      main.tsx App.tsx api.ts theme.ts styles.css
      components/{QuotaCard.tsx,ResetList.tsx,AgentTable.tsx,GitPanel.tsx,Alerts.tsx,SourceStatus.tsx}
    public/fonts/ public/font-licenses/
  packages/contracts/package.json src/{index.ts,schemas.ts}
  probes/{probe.py,terminal.py,profiles.py,requirements.txt}
  tests/unit/{contracts,quota,alerts,scheduler,redaction,identity}.test.ts
  tests/integration/{http,sqlite,git,tmux,herdr,probe-boundary,collector}.test.ts
  tests/python/test_{terminal,profiles,probe}.py
  tests/e2e/{dashboard,staleness,keyboard,read-only}.spec.ts
  tests/fixtures/{usage,herdr,manifests,malformed}/
  tests/helpers/{fake-cli.py,fake-herdr.ts,git-fixture.ts,server-process.ts}
  scripts/{build.mjs,verify.sh,preflight.mjs,probe-doctor.mjs,smoke.mjs,check-policy.mjs}
  docs/{REFERENCE_PATTERNS,DECISIONS,CLI_PROFILES,OPERATIONS,SECURITY}.md
  vitest.unit.config.ts vitest.integration.config.ts playwright.config.ts
  .github/workflows/ci.yml
```

Ignored: `.venv`, `node_modules`, all dist, `.local`, `.artifacts`, SQLite/WAL files, `config/dashboard.local.json`, `.env*` except `.env.example`, screenshots, raw terminal captures. Fonts are owner brand assets; retrieve OFL notices from the upstream font sources and retain attribution. If notices cannot be obtained, use fallback system font stacks and record the asset gap; typography capability must still pass tests without network.

### Contracts and storage

All timestamps are ISO-8601 UTC strings with millisecond precision. Store source timezone separately; UI formats both local absolute reset and countdown using `America/New_York`. Inject `Clock.now()` for all domain calculations. IDs and dates pass Zod validation before storage or UI. Unknown is never encoded as zero.

| Type | Required fields and semantics |
| --- | --- |
| `SourceHealth` | `sourceId`, `status` = ok/missing/not_authenticated/disabled/unsupported/timeout/parse_error/stale, `checkedAt`, `lastSuccessAt: string|null`, `reasonCode`, `cliVersion: string|null`, `parserVersion`, `provenance` = live/fixture; no raw stderr |
| `QuotaWindow` | `kind` = five_hour/weekly, `scope` = all/sonnet/opus/model identifier, `availability` = known/unknown/not_applicable, `usedPercent: number|null`, `remainingPercent: number|null`, `resetsAt: string|null`, `resetRaw: string|null` (strictly sanitized short reset text), `sourceTimezone: string|null`, `sampledAt`, `confidence` = exact/rounded/unknown |
| `ProviderQuota` | `provider` = claude/codex/grok, `windows: QuotaWindow[]`, `bankedResets: BankedReset[]|null`, `bankedStatus` = known/unknown/not_applicable, `health: SourceHealth`; unknown banked list is null, known empty is `[]` |
| `BankedReset` | `id`, `quantity` positive integer, `earnedAt: string|null`, `expiresAt: string|null`, `redeemableAt: string|null`, `eligibility` = eligible/ineligible/unknown, `eligibilityReason: string|null`, `sampledAt`; CLI-reported values only |
| `AgentSession` | `id` (namespaced), `provider: string`, `runtime`, `sessionIdentity: string|null`, `workspaceId`, `paneId`, `label`, `cwd: string|null`, `status` = idle/working/blocked/done/unknown, `stateChangeSeq`, `enteredAt`, `lastOutputAt: string|null`, `observedAt`, `evidenceSource` = herdr/tmux/manifest, `confidence`, `pid: number|null`, `loop: LoopInfo|null` |
| `LoopInfo` | `kind` = goal/loop/workflow/custom/unknown, `state` = running/waiting/finished/unknown, `iteration: number|null`, `objective: string|null` (sanitized and max 160 chars), `source` = manifest/process; never infer an active `/goal` from a plain `grok` process |
| `GitWorktree` | `id`, `repositoryId`, `path`, `branch: string|null`, `head`, `detached`, `locked`, `prunable`, `staged`, `modified`, `untracked`, `conflicted` integer counts, `recentCommits` max 5 `{sha,subject,committedAt}`, `observedAt`, `health`; no diffs or file content |
| `Alert` | stable `id` from rule/provider/scope/reset-or-expiry identity, `kind`, `severity` = info/warning, `provider`, `subjectId`, `message`, `createdAt`, `evaluatedAt`, `evidence` structured safe values; no mutation/acknowledge API |
| `DashboardSnapshot` | `schemaVersion:1`, monotone `sequence`, `generatedAt`, `providers`, `sessions`, `worktrees`, `alerts`, `sources`, `mode` = passive/live/fixture |

SQLite tables: `schema_migrations(version PRIMARY KEY, applied_at)`, `quota_samples(id, provider, sampled_at, payload_json)` indexed on provider/time, `source_health(source_id PRIMARY KEY, payload_json)`, `session_state(id PRIMARY KEY, session_identity, status, entered_at, last_output_at, observed_at, payload_json)`, `git_cache(id PRIMARY KEY, payload_json)`, `alerts(id PRIMARY KEY, created_at, last_seen_at, payload_json)`. Quota history retains seven days; git/session state only latest; disappearances age out after 24h. Store only normalized/redacted data, never terminal screen text or credential-related environment. SQLite at `.local/dashboard.sqlite`, private directory 0700/file 0600. A change of session identity or process start identity resets dwell; reconnect with the same identity does not reset dwell. Out-of-order collector results cannot overwrite newer observations.

Interfaces: `CommandRunner.run({executable,args,cwd,timeoutMs,maxBytes,allowedEnvironment}) -> {code,stdout,stderr}`; `SessionSource.collect(signal) -> {sessions,health}`; `QuotaSource.collect(provider,signal) -> ProviderQuota`; `GitSource.collect(roots,signal) -> {worktrees,health}`; `Clock.now() -> Date`; `SnapshotRepository.read()/apply(observation)`; `AlertEngine.evaluate(snapshot,now,coverage) -> Alert[]`. An unsuccessful collection updates health but preserves the last successful sample with its original timestamp. Snapshot assembly calculates stale status; it never republishes an old sample with a new `sampledAt`.

### Collector rules

Configuration JSON has `schemaVersion:1`, `host:"127.0.0.1"`, `port:4317`, `timezone:"America/New_York"`, `mode:"passive"`, `repositoryRoots:[]`, `herdrSocket:null`, `tmuxSocket:null`, `quotaProbesEnabled:false`, `providers:{claude:{executable:"claude",profile:null},codex:{executable:"codex",profile:null},grok:{executable:"grok",profile:null}}`, `poll:{sessionsSeconds:10,gitSeconds:30,quotaSeconds:300}`. Repository roots are explicit existing directories; discovery never recursively walks the user's home. Validate intervals (minimum 10/30/300 seconds), local paths, ports, and mode. `mode=fixture` can only be selected by `HERDR_FIXTURE=1`; it overrides all real collectors and uses synthetic data. `mode=live` requires `quotaProbesEnabled:true` and a supported profile, but is still read-only with respect to agent work and account actions.

- herdr: explicit config socket, `HERDR_SOCKET_PATH`, then XDG config default, then `~/.config/herdr/herdr.sock`. For named `HERDR_SESSION`, use the installed, documented `herdr session list` registry or validated session name path; if unresolved report it and fall back visibly. Never start herdr. Use only `agent.list` and `session.snapshot` in v1, every ten seconds. Node `net` NDJSON requests, decimal string IDs, optional numeric matching; 2s total deadline, 4 MiB frame cap, one reconnect retry for reads. `agent.list` contains `{agents:[...]}`; drop missing agent/pane IDs, map `agent_session`, preserve unknown provider names and state seq. Unknown/old protocol shows compatibility warning, never enables a write capability. Deduplicate identical observed PID+cwd across sources; if identity is uncertain keep separate labeled rows.
- tmux: `tmux list-panes -a -F '#{session_id}\t#{session_name}\t#{window_id}\t#{window_name}\t#{pane_id}\t#{pane_pid}\t#{pane_current_command}\t#{pane_current_path}\t#{pane_dead}'` (literal tab separators in the actual format argument); optional `-S` precedes the subcommand for an explicit socket. Use `ps`/Linux `/proc` read-only process ancestry to recognize a CLI executable, including Node wrappers; do not inspect environ. Treat command line as sensitive, keep only executable/provider and recognized loop flags, do not store full argv. A shell pane is not an agent. Process existence proves running process, not working/idle/blocked status. No capture-pane by default and no keyboard injection. `unknown` is the default tmux agent status without an explicit local manifest.
- loops: read an optional `.herdr-dashboard/run.json` **inside an allowlisted worktree**, maximum 16 KiB, no symlink escape, schema 1 with `sessionIdentity`, `provider`, `pid`, `processStartTicks`, `kind`, `state`, `iteration`, `objective`, `updatedAt`. Verify PID start time and matching cwd; a stale/dead/mismatched manifest cannot prove a running loop. The executor must not instrument or alter existing loops; document this optional contract for future supervisors.
- git: per root run `git -C <root> rev-parse --show-toplevel`, `git -C <root> worktree list --porcelain -z`, then per allowed worktree `git status --porcelain=v1 -z --untracked-files=normal`, `git symbolic-ref --quiet --short HEAD`, `git rev-parse HEAD`, `git log -5 --format=%H%x00%cI%x00%s%x00`. Parse NUL records and rename pairs; no fetching, network, hooks, `safe.directory` global changes, `git diff`, or commit/file body reads. Worktrees outside explicit allowed roots get an excluded metadata entry; do not open them automatically. Handle unborn/detached branches, locked/prunable trees, unreadable repos, spaces/newlines in filenames, and conflicts.
- quotas: invoke an installed executable's safe `--version`/help only with deadlines. Python PTY uses `pty`, `os`, `select`, `signal`, `termios`, `fcntl` plus pyte; render cursor movements/ANSI redraw into a screen, do not regex the accumulated raw byte stream. Profiles are versioned exact CLI version ranges supported by fixture evidence; do not assume matching CLI major means the UI stayed compatible. Start in a private empty cwd with filtered environment, no prompt argument, no resume/continue flags. Strip `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `XAI_API_KEY`, vendor API base overrides, preload/debug variables; preserve the CLI's normal existing subscription login without reading its files. Apply official hook/plugin disabling flags only if installed help documents them; if arbitrary global startup hooks/MCP cannot be disabled or shown inert, mark profile unsafe and do not launch. No automatic trust acceptance. Readiness must match an anchored known empty input screen; trust/login/onboarding/update screens abort.
- probe state machine: started -> empty_prompt -> command_sent -> known_usage_screen -> parsed -> shutdown. Total 20s, max 512 KiB PTY output, 160x50 screen, one active probe globally. Confirm the executable absolute path at configuration/profile discovery; do not dispatch a provider label through a shell or PATH lookup that can change mid-probe. Only exact diagnostic slash commands and verified non-destructive menu navigation appear in a profile; Escape is allowed only on known probe screens. Return one bounded JSON result on stdout; raw screen stays in memory and is discarded. Stderr contains only reason codes. Kill only the child process group started by this helper; never kill a user tmux session.
- Claude: `/usage`; parse current 5h session plus overall weekly and any separate model-specific weekly labels. Codex: `/status` for 5h/weekly quota; `/usage` for visible earned reset inventory. Token activity views are not quota. Never select **Redeem reset** merely because it is present. If installed evidence proves that an initial submenu is inventory-only with redemption requiring a separate confirmation, allow only that specific inventory navigation and block all apply/confirm buttons and terminal states. If opening the submenu itself could redeem, stop and report banked inventory unknown. Grok: `/usage`; weekly known when labeled; 5h **not applicable** unless this version explicitly reports a real 5h quota. Do not invent Grok's 5h reset from other providers.
- Percentages: accept explicitly labeled `% used` or `% left`, normalize to [0,100], reject impossible values/ambiguous bare percentages. Preserve rounded precision. Reset times require full date+zone/offset, or a relative duration anchored to the captured screen time. For local weekday/time use configured zone with explicit next occurrence; if DST fold or missing week context is ambiguous, retain reset text and null absolute reset rather than guessing. Never assume a five-hour duration begins at probe startup, or calculate current quota from logs.

### Alert rules

Evaluate once per minute and on successful observations. Quota TTL = 10 minutes, session coverage TTL = 30 seconds, git TTL = 90 seconds. Exact threshold equality belongs to the non-trigger side unless stated below.

1. `window_open_idle`: fresh known overall 5h quota with `remainingPercent >= 20`, weekly known with `remainingPercent > 0`, future reset if a reset is reported, complete fresh enabled session-source coverage, and zero working/blocked/unknown live sessions for that provider continuously for at least ten minutes. Known idle/done sessions are permitted. An uncertain tmux agent suppresses this alert. Grok receives no 5h idle alert when that window is not applicable.
2. `weekly_reset_underused`: fresh known overall weekly quota with `remainingPercent >= 40` and `0 < resetsAt-now < 48h`. Per-model quotas display separately; do not double-count the overall alert.
3. `banked_reset_unusable_before_expiry`: known banked expiry and explicit CLI-reported `redeemableAt >= expiresAt`, or explicit permanent ineligibility reason. Explain the reported reason; no unsupported formula for reset redemption rules.
4. `banked_reset_expiring`: known unused reset with `0 < expiresAt-now < 48h`, unless rule 3 already applies. If redemption eligibility is unknown, message says “expires soon; eligibility unknown,” not “cannot be used.” Expired resets remain labeled expired and are excluded from usable totals.
5. `source_problem`: source disabled, absent, unauthenticated, timeout, unsupported, or stale; deduplicate per source/reason. Source alerts must not drown out usage cards; render them in source status.

IDs stay stable across polls; retain original createdAt until the condition resolves. Never evaluate capacity alerts from fixture data in live mode, stale data, missing windows, unknown reset times, or incomplete session coverage. Browser alerts are display-only; no email/webhook/browser permission flow.

### HTTP surface and browser

Every JSON response uses `Content-Type: application/json`, `Cache-Control: no-store`; errors are `{error:{code,message}}`, no stack trace. Reject Host values other than the exact bound loopback authority (`127.0.0.1:<port>` or `localhost:<port>`); reject foreign Origin and cross-site fetch metadata. Vite-origin allowance exists only in explicit development mode. No CORS wildcard. CSP defaults to self, no inline script, no external fonts; escape metadata and treat all labels as text.

| Method/path | Response |
| --- | --- |
| GET `/api/health` | 200 `{status:"ok",schemaVersion:1,mode,readOnly:true}` when HTTP/storage work; source failures appear separately |
| GET `/api/snapshot` | 200 `DashboardSnapshot` |
| GET `/api/providers` | 200 `{providers:[ProviderQuota...]}` in claude/codex/grok order |
| GET `/api/sessions` | 200 `{sessions:[AgentSession...]}` |
| GET `/api/worktrees` | 200 `{worktrees:[GitWorktree...]}` |
| GET `/api/alerts` | 200 `{alerts:[Alert...]}` |
| GET `/api/events` | SSE `event:snapshot`, `id:<sequence>`, sanitized JSON; 15s heartbeat, 64 KiB/client buffered cap, latest snapshot on connect/reconnect; no historical transcript |
| GET unknown `/api/*` | 404 JSON; never fall through to SPA |
| POST/PUT/PATCH/DELETE `/api/*` | 405, `Allow: GET`; unknown action routes remain absent |
| GET `/` and UI routes | Built frontend with source health visible; static files only inside web dist |

UI: quota strip with three named cards, visual meter and text used/left, explicit 5h/weekly reset times, freshness/source badges; Codex inventory adjacent to its card; alert list; attention-first agent table; worktree detail panel with branch/counts/five recent commits. Filters by provider/status/search (client only) and expandable rows are allowed. Only controls are filters, detail expansion, and light/dark theme; no “start,” “stop,” “approve,” “redeem,” or server refresh action. Passive mode clearly states probes disabled. Fixture mode always displays “Demo data.” At 1440x900 all provider cards and first agent rows are visible; at 390x844 use vertical cards, accessible table overflow, no body horizontal scroll. Use semantic progress elements, numeric text, aria labels, keyboard navigation, 44px touch targets, color-independent states, and reduced motion.

## 3. Milestones

### Common gate and commit protocol

Milestone 01 establishes these root scripts. Every subsequent milestone must run `npm run check`, which executes, sequentially, `lint`, `typecheck`, `test:unit`, `test:python`, `build`, `test:integration`. All commands exit 0; Vitest/Python report executed passing tests, zero failures and zero skips. Build creates `apps/server/dist/main.js` and `apps/web/dist/index.html`. Bootstrap uses `npm install` with the listed exact dependencies to produce the first real lockfile before the acceptance `npm ci`; never fabricate a lockfile. `test:unit -- <path>` and `test:integration -- <path>` select an actual nonempty named suite. `test:python` is `.venv/bin/python -m unittest discover -s tests/python -v`. `test:e2e` runs the root Playwright config against an isolated production fixture server, not Vite. At early milestones use meaningful foundation smoke suites; add new named suites as their boundaries become available. Never `--passWithNoTests`. `npm run check:policy` verifies allowed commands, ignored sensitive artifacts, no mutation APIs, pinned direct dependencies, and new repo branch. Do not globally scan or print reference secret files.

Root script mappings: `lint` = `eslint . --max-warnings=0`; `typecheck` invokes `tsc --noEmit` for the root server/contracts source config and separate web config; `test:unit` = `vitest run --config vitest.unit.config.ts`; `test:integration` = `vitest run --config vitest.integration.config.ts`; `test:e2e` = `playwright test --config playwright.config.ts`; `build` runs a Node build helper that applies the esbuild server options above then Vite in apps/web; `start` = `node apps/server/dist/main.js`; `check:policy` = `node scripts/check-policy.mjs`. Add `scripts/build.mjs` in01 and list it in the scripts folder. The combined `check` script executes the six specified scripts sequentially and stops on first failure.

After each acceptance block: update the log, run `git diff --check`, stage the milestone's named files plus log, run `git diff --cached --check`, inspect diff, commit with the milestone message. Done checkboxes are requirements, not prechecked claims.

### 01. Bootstrap a runnable loopback repository

**Objective:** A reproducible toolchain, static page, working health API, and test runners before domain work.

**Steps:**

1. Verify branch/new repo boundary and read the reference paths.
2. Record source hashes and decisions; create hard-rule AGENTS and ignored artifact paths.
3. Create workspaces, exact pins, lockfile, lint/strict TS/Vite/server builds, Python venv requirements, and Playwright configuration.
4. Implement minimal loopback server and page titled `herdr dashboard`, health JSON, bounded shutdown.
5. Add real HTTP smoke, contract smoke, Python emulator smoke, and page-title e2e; wire check scripts.
6. Validate Node version and resolve/install pins, handling version blockers under the rule above.

**Files:** Root configs/logs/docs, apps package/config/main files, contracts package, probes requirements, foundation tests/helpers, `scripts/preflight.mjs`.

**Acceptance:**
```bash
npm ci
python3 -m venv .venv
.venv/bin/python -m pip install -r probes/requirements.txt
npm exec playwright install chromium
npm run check
npm run test:e2e -- tests/e2e/dashboard.spec.ts
node scripts/preflight.mjs --json
```
Expected: every command exits 0; preflight JSON has `coreReady:true`, `platform:"linux"`; unavailable optional CLIs are reported without core failure. HTTP integration asserts 127.0.0.1 binding, health status 200/readOnly true, and graceful process exit. The page test passes.

**Done:**

- [x] Branch and logs exist.
- [x] Lockfile reproducible.
- [x] All three test runners execute tests.
- [x] Built page and server exist.
- [x] Commit `chore: bootstrap Linux dashboard workspace`.

### 02. Define normalized contracts and deterministic fixture catalog

**Objective:** Shared truthful quota/session types and known fixture coverage.

**Steps:**

1. Add every model and interface specified above with runtime schemas.
2. Create synthetic normalized scenarios `daily`, `missing`, `stale`, `partial`, `dst`, `banked-expiring`, `unknown-loop`; include raw synthetic TUI screens separately. Use fixed `2026-09-29T16:00:00.000Z` in fixtures.
3. Set daily fixture to Claude 5h 10% used/weekly 20%, Codex 5h 65% left/weekly 75% left, Grok weekly 15% used/5h not applicable. Set Claude and Codex 5h resets to now+4h; weekly resets are Claude now+36h, Codex now+37h, Grok now+47h. Include a Codex reset expiring in24h and another expiring in24h but explicitly CLI-reported redeemable at now+25h. Daily fake session coverage is fresh/complete with one known working session per provider, so it does not trigger idle alerts; the separate idle scenario removes work and advances the clock.
4. Add contract tests rejecting invalid numbers, invalid dates, missing provenance, and zero substituted for unknown.

**Files:** `packages/contracts/src/*`, `tests/fixtures/usage/*`, `tests/unit/contracts.test.ts`, `docs/DECISIONS.md`.

**Acceptance:** `npm run test:unit -- tests/unit/contracts.test.ts` then `npm run check`. Expected all scenarios validate; invalid samples fail validation; daily providers exactly three; Grok five_hour null/not_applicable; unknown banked list null differs from known empty `[]`.

**Done:**

- [x] Models match tables.
- [x] Fixtures synthetic and labeled.
- [x] Null semantics enforced.
- [x] Commit `feat: define quota and herd contracts`.

### 03. Add local SQLite storage, migrations, and redaction

**Objective:** Persistence survives restarts without storing secret-bearing raw evidence.

**Steps:**

1. Write migration 001 with specified constraints/indexes; apply transactionally on startup.
2. Normalize and redact before storage: credential-like prefixes, bearer headers, URL credentials/query tokens, emails, and multiline terminal/control content; only normalized fields accepted.
3. Implement upserts with observation ordering and seven-day cleanup; use injected clock.
4. Private permissions, lock contention bounded retry, controlled corruption error (no auto-delete).
5. Test duplicate startup, restart, older observation rejection, retention, WAL permissions, and sentinel leakage across HTTP/storage/log outputs.

**Files:** Storage/service files, `tests/integration/sqlite.test.ts`, `tests/unit/redaction.test.ts`, `docs/SECURITY.md`.

**Acceptance:** `npm run test:unit -- tests/unit/redaction.test.ts`; `npm run test:integration -- tests/integration/sqlite.test.ts`; `npm run check`. Expected migrations apply twice without duplicates; restart preserves the sample/dwell; database excludes `SYNTHETIC_SECRET_SENTINEL`; old samples pruned; fixture SQLite file mode is 0600.

**Done:**

- [x] Transactional migration.
- [x] Retention and ordering tested.
- [x] No raw capture persistence.
- [x] Commit `feat: persist sanitized observations locally`.

### 04. Implement bounded process execution and configuration

**Objective:** Every system observation goes through an audited boundary.

**Steps:**

1. Validate config and defaults, explicit repo root allowlist, loopback host, probe enable gate.
2. Implement runner with argument arrays, output caps, timeout, abort, filtered env, private working directory, and process-group cleanup.
3. Deny shells, git mutators, tmux key/input commands, real API-key env propagation, invalid executable/path shapes.
4. Add fake processes that hang/flood/exit badly; validate hostile branch/path strings stay literal arguments.
5. Expose capability-only doctor results, no full environment or command line.

**Files:** `config/dashboard.example.json`, config/command-runner, `tests/integration/probe-boundary.test.ts`, policy script, doctor skeleton.

**Acceptance:** `npm run test:integration -- tests/integration/probe-boundary.test.ts`; `npm run check:policy`; `npm run check`. Expected shell metacharacter test creates no sentinel file, flooded child stopped before storage, timed-out process group reaped, probes disabled by default, nonloopback host rejected.

**Done:**

- [x] Command allowlist.
- [x] Env filtering.
- [x] Cancellation cleanup.
- [x] Commit `feat: constrain local collector execution`.

### 05. Collect git repositories and worktrees

**Objective:** Accurate branch, commit, and uncommitted counts without modifying source repos.

**Steps:**

1. Implement specified git command sequence and NUL parsers.
2. Canonicalize roots and enforce outside-root exclusion; deduplicate repository common dirs.
3. Handle renames, staged/unstaged overlap, untracked files, conflicts, unborn HEAD, detached HEAD, missing worktree paths. Counts represent each category, so one file can contribute to both staged and modified.
4. Integration setup creates temp repo with two commits/two worktrees, a staged file, modified file, untracked file, and separate conflict fixture. Use synthetic author identity.
5. Compare status/content/HEAD before and after collection; prove no changes.

**Files:** Git adapter, git fixture helper, `tests/integration/git.test.ts`.

**Acceptance:** `npm run test:integration -- tests/integration/git.test.ts`; `npm run check`. Expected exactly two allowed worktrees, correct distinct branches, recent SHA/time/subject, expected fixture counts 1 staged/1 modified/1 untracked, separate conflict count 1; repo HEAD/status/content unchanged; filenames with spaces/newlines survive parsing; outside-root worktree is excluded.

**Done:**

- [x] Worktree metadata complete.
- [x] Read-only observation proven.
- [x] Detached/error states tested.
- [x] Commit `feat: collect git worktree activity`.

### 06. Collect tmux agents and optional loop manifests

**Objective:** Detect running processes without pretending process existence reveals a model's state.

**Steps:**

1. Implement tmux format parser, optional socket, missing-server health.
2. Resolve process ancestry read-only, identify Claude/Codex/Grok Node wrappers, omit plain shells.
3. Validate optional loop manifest against PID/start ticks/cwd/age (fresh <=30s), reject stale/spoofed/symlink escape.
4. Unit test parsed fixture records and fake command-runner responses.
5. If installed tmux is available, test on a private `tmux -L chhaya-dashboard-test-<random>` server with synthetic agents; cleanup only that socket. If absent, record gap and execute deterministic tmux command-protocol tests; do not mark live tmux tested.

**Files:** Tmux adapter, session/identity helpers, manifest schema/fixtures, `tests/integration/tmux.test.ts`, `tests/unit/identity.test.ts`.

**Acceptance:** `npm run test:integration -- tests/integration/tmux.test.ts`; `npm run test:unit -- tests/unit/identity.test.ts`; `npm run check`. Expected fake records yield three agent rows and no shell row; each process-only row status unknown; valid manifest identifies goal/running, stale or PID-reused manifest cannot; adapter never sends `send-keys`, `capture-pane`, `kill-session`, or writes a worktree.

**Done:**

- [x] tmux absence supported.
- [x] Unknown classification honest.
- [x] Loop evidence validated.
- [x] Commit `feat: observe tmux sessions and loop manifests`.

### 07. Implement the Linux herdr read adapter

**Objective:** Preserve the Shepherd model over the actual NDJSON transport.

**Steps:**

1. Port the documented read envelope/normalization, not Swift code/toolchain.
2. Use authoritative `agent.list` and snapshot labels, namespace IDs `herdr:<socket-hash>:<workspaceId>:<paneId>`.
3. Test fake Unix socket frames split/coalesced, out-of-order IDs, numeric IDs, null/errors, oversized/no-newline data, timeout/reconnect, removed pane, changed occupant, old/new protocol.
4. Reconcile with tmux only on strong process/cwd identity; preserve unmatched sources.
5. Document read concept mapping to Shepherd/MCP and why no wire MCP server is needed in v1.

**Files:** Herdr adapter/fake socket helper, `tests/integration/herdr.test.ts`, session service, `docs/REFERENCE_PATTERNS.md`.

**Acceptance:** `npm run test:integration -- tests/integration/herdr.test.ts`; `npm run check`. Expected authoritative agent list excludes shell; labels/cwd/seq retained, unknown status maps unknown, oversized frame rejected, connection failure shows missing with prior state stale, server sees only `agent.list` and `session.snapshot` method names.

**Done:**

- [x] Real Unix socket test.
- [x] Wire framing bounded.
- [x] No write methods.
- [x] Commit `feat: reuse herdr read model on Linux`.

### 08. Build the PTY emulator and fail-closed diagnostic state machine

**Objective:** Read genuine interactive terminal behavior without relying on real accounts.

**Steps:**

1. Implement Python PTY terminal rendering/state machine and structured result protocol.
2. Fake CLI fixture uses a TTY check and ANSI cursor redraw; accepts only expected slash commands, tracks keystrokes, includes trap states for trust/model prompt/redemption.
3. Test width/Unicode/cursor clear/wrapping, timeouts, no newline, redraw fragments, exit mid-screen, no subscription login, unknown version, and cancellation.
4. Profile validation refuses any prose, resume flag, action key, arbitrary Enter on menu, unsupported startup configuration, or unrecognized screen.
5. Node adapter consumes only bounded validated JSON, no raw stdout pass-through.

**Files:** Python probe/terminal/profiles, fake CLI, Python tests, quota-probe adapter and boundary integration tests, `docs/CLI_PROFILES.md`.

**Acceptance:** `npm run test:python`; `npm run test:integration -- tests/integration/probe-boundary.test.ts`; `npm run check`. Expected fake CLI confirms `isatty` true; ANSI latest-screen parse matches fixture; trust/redemption traps receive no accepting input; timeout <=22s; no orphan child; probe stdout exactly one valid JSON result and no captured screen.

**Done:**

- [x] Real PTY coverage.
- [x] Known empty-prompt gate.
- [x] Action traps tested.
- [x] Commit `feat: add safe CLI quota probe transport`.

### 09. Parse provider quotas and Codex reset inventory

**Objective:** Three provider-specific parsers produce truthful normalized data.

**Steps:**

1. Implement Claude `/usage`, Codex `/status` + safe visible `/usage` inventory, Grok `/usage` profiles from synthetic screen fixtures and installed help where accessible.
2. Explicit used/left normalization and separate model scopes.
3. Parse relative/absolute reset time, TZ offsets, New York DST boundaries, malformed and ambiguous strings; preserve unknowns.
4. Codex inventory tests cover quantity, expiry, eligibility, known zero, unknown list, expired entry, and no auto-redemption.
5. Live profile discovery is read-only; if a CLI is unavailable/not authenticated or its banked screen is unsafe, document the exact capability gap. Implement adapters nonetheless and demonstrate end-to-end using fake TUIs.

**Files:** Provider parser/profile modules, quota unit/Python tests, fixtures, `docs/CLI_PROFILES.md`, `BLOCKERS.md`.

**Acceptance:** `npm run test:unit -- tests/unit/quota.test.ts`; `npm run test:python`; `npm run test:integration -- tests/integration/collector.test.ts`; `npm run check`. Expected daily screen fixtures yield the exact percentages in milestone 02; “65% left” yields 35% used; Grok 5h not_applicable; bad/ambiguous dates null; Codex quantity/expiry preserved; keystroke audit contains no redeem/apply confirmation. All three fake CLIs are probed through PTYs, not bypassed with pre-normalized quota JSON.

**Done:**

- [x] All provider adapters complete.
- [x] Banked gap distinguished from zero.
- [x] Time ambiguity tests.
- [x] Commit `feat: read CLI subscription quotas and reset inventory`.

### 10. Schedule collectors and expose immutable HTTP snapshots

**Objective:** Responsive API, consistent freshness, no overlapping probes or corrupt state.

**Steps:**

1. Add session/git/quota cadence and single-flight global probe semaphore; backoff source failures 5/10/20/30 minutes for quota and max60s session failures, reset after success.
2. Collect at startup, then schedule; config changes require restart.
3. Assemble/store atomic snapshot sequence; prevent stale observations replacing newer ones.
4. Implement all GET routes/security headers/SSE caps; mutating methods 405 and unknown API routes 404.
5. Stop timers and owned processes on SIGTERM/SIGINT.
6. Fixture server uses fake collectors, fixed clock (advance via test harness configuration, not public endpoint), isolated DB, and no host collection.

**Files:** Scheduler, snapshot, HTTP/security/main, HTTP/scheduler/collector tests, server process helper.

**Acceptance:** `npm run test:unit -- tests/unit/scheduler.test.ts`; `npm run test:integration -- tests/integration/http.test.ts`; `npm run check`. Expected frozen clock drives exact cadence; simultaneous quotas never overlap; failed probe retains original sampledAt; foreign Host/Origin 403; POST 405; unknown API 404; SSE valid sequence grows and reconnect gets latest snapshot; health 200 with broken optional providers.

**Done:**

- [x] Cached API never waits for CLI.
- [x] TTLs visible.
- [x] Shutdown bounded.
- [x] Commit `feat: serve scheduled read-only dashboard snapshots`.

### 11. Implement capacity and expiry alerts

**Objective:** Every alert has a deterministic, evidence-based predicate.

**Steps:**

1. Implement the five alert rules and stable IDs/creation ledger.
2. Add boundary tests for exactly48h, one millisecond under48h, remaining40/20%, ten-minute idle dwell, weekly exhausted, expired dates, stale quota, missing/unknown agent sources, and Grok not_applicable.
3. Banked inability uses only explicit CLI-reported constraints; no predicted burn rate or invented eligibility.
4. Remove resolved alerts atomically; recurring same condition retains createdAt until resolution.

**Files:** Alert service, `tests/unit/alerts.test.ts`, alert fixtures.

**Acceptance:** `npm run test:unit -- tests/unit/alerts.test.ts`; `npm run check`. Expected fixed daily scenario yields weekly-underused Claude/Codex/Grok, one expiring and one unusable Codex reset; idle alert appears only after simulated ten minutes with full known coverage. Unknown tmux activity/stale usage suppress capacity alerts. Exactly48h does not trigger.

**Done:**

- [x] Thresholds explicit.
- [x] False-positive suppression tested.
- [x] Stable identity.
- [x] Commit `feat: surface idle capacity and reset expiry alerts`.

### 12. Build quota cards, banked inventory, themes, and source status

**Objective:** Daily capacity is readable immediately at desktop and phone sizes.

**Steps:**

1. Copy audited brand tokens/fonts/notices or documented system fallbacks.
2. Build three cards with percentage text/meters, 5h/weekly reset absolute/time-left displays, scope detail, Codex banked list, health and freshness.
3. Implement shared theme with persistence/system fallback and no external network.
4. Render null, not_applicable, stale-last-known, and disabled distinctly; no stale meter implies fresh.
5. Add fixture/provenance label and accessible empty/error/loading states.
6. Update production browser tests for all three providers and themes.

**Files:** Web components/CSS/theme/api, public assets, `tests/e2e/dashboard.spec.ts`, `tests/e2e/staleness.spec.ts`.

**Acceptance:** `npm run check`; `npm run test:e2e -- tests/e2e/dashboard.spec.ts tests/e2e/staleness.spec.ts`. Expected text includes Claude/Codex/Grok, actual fixture reset times, banked expiry, “Demo data,” and “Not applicable” for Grok5h; missing quota says unknown; stale sample original timestamp visible; theme survives reload; browser records zero off-loopback requests and zero uncaught exceptions.

**Done:**

- [x] Capacity and resets visible.
- [x] Health truthful.
- [x] Dark/light readable.
- [x] Commit `feat: display provider quota and banked reset cards`.

### 13. Build session triage, loop and worktree details, and alert views

**Objective:** Connect capacity with the actual work running and waiting.

**Steps:**

1. Agent table sorts blocked, working, idle, done, unknown with stable identity tie-break; present enteredAt/dwell/provenance without claiming tmux unknown is idle.
2. Provider/status/search filters, expandable row with loop proof and git branch/counts/commits; map cwd to most specific allowed worktree.
3. Separate unmapped worktree panel; failure health visible.
4. Display capacity alerts with source/evidence; source failures grouped in source status.
5. Escape and keyboard close detail, semantic table, no hidden action controls.

**Files:** AgentTable/GitPanel/Alerts, `tests/e2e/dashboard.spec.ts`, `tests/e2e/keyboard.spec.ts`.

**Acceptance:** `npm run check`; `npm run test:e2e -- tests/e2e/dashboard.spec.ts tests/e2e/keyboard.spec.ts`. Expected fixture search narrows to matching agent; expanding shows exact branch/counts/two recent SHA entries; goal manifest row labeled goal/running and process-only loop unknown; alert appears/disappears on harness clock scenario; all interactions keyboard operable.

**Done:**

- [ ] Work linked by cwd.
- [ ] Loop certainty visible.
- [ ] No action paths.
- [ ] Commit `feat: show agent triage and git work details`.

### 14. Verify read-only security, degraded operation, and browser resilience

**Objective:** Failures and hostile input cannot cause mutation or leaks.

**Steps:**

1. Policy test walks exported adapters/routes and integration-observed commands; forbid mutators rather than relying on UI absence.
2. Inject malicious labels/commit subjects/control bytes/HTML/path traversal/URL credentials; no executable DOM or secret sentinel in responses/DB/log artifacts.
3. Missing/all-disabled providers, expired cached sample, socket crash, hung PTY, git timeout, browser reconnection.
4. Assert read-only controls list; no start/stop/approve/redeem network requests.
5. 1440x900 and390x844, reduced motion, forced font failure, focus outlines and no body overflow. Fix discovered issues without dropping scenarios.

**Files:** Security/redaction/policy improvements, `tests/e2e/read-only.spec.ts`, keyboard/staleness tests, `docs/SECURITY.md`.

**Acceptance:** `npm run check:policy`; `npm run check`; `npm run test:e2e`. Expected all non-GET methods fail; no foreign request; malicious strings rendered as text; no secret sentinel; zero unhandled browser errors; viewport overflow assertion `document.documentElement.scrollWidth <= innerWidth` passes; graceful missing sources keep dashboard usable.

**Done:**

- [ ] Mutation/leak audit exercised.
- [ ] Degraded screen coverage.
- [ ] Phone/reduced-motion checks.
- [ ] Commit `test: verify safe degraded dashboard operation`.

### 15. Write operations, provider doctor, and offline CI

**Objective:** Owner can run the built app and distinguish implementation from installed-account coverage.

**Steps:**

1. Complete README commands `npm ci`, Python setup, build, `npm start`, config copy, passive/live/fixture distinctions, stop instructions.
2. Doctor `node scripts/probe-doctor.mjs --json` runs versions/help only by default; `--live` performs only verified safe diagnostic PTYs, outputs normalized data/status codes, and never an auth URL/token/screen.
3. Document CLI profile update workflow, banked inventory limitations, optional manifest schema, safe private tmp ownership, backup/retention and corrupt DB handling.
4. CI ubuntu22.04 Node22.23.2 Python3.13.7, npm ci/venv/browser/check/e2e, no secrets, no deploy, permissions contents:read.
5. Local machine-check CI policy parses required stages (use built-in JSON representation emitted by own config check; do not pretend local execution proves hosted Actions availability).

**Files:** README/docs, complete doctor/preflight, CI config, policy test.

**Acceptance:** `node scripts/probe-doctor.mjs --json` exits0 for diagnostic reporting (even missing optional CLI) with three provider entries; `npm run check:policy`; `npm run check`; `npm run test:e2e`. Expected no copied tokens, no live probe without `--live`, all CI commands correspond to root scripts. BLOCKERS names each unverified live capability explicitly.

**Done:**

- [ ] Start/run instructions exact.
- [ ] Doctor safe by default.
- [ ] CI defined locally.
- [ ] Commit `docs: add Linux operations and offline verification CI`.

### 16. Deliver independent reproducible evidence

**Objective:** A fresh reviewer proves the complete local product without installed agent accounts.

**Steps:**

1. Implement the verification script below and smoke/policy helpers to assert content, not only print pass banners.
2. Run it twice from repo root with clean isolated runtime directories; second run must not rely on old DB/artifacts.
3. Final review compares all requirements to test names and artifacts, includes real PTY fake CLI, Unix socket, git temporary worktrees and production page.
4. Add final evidence table to progress, resolved/outstanding external gaps to blockers.
5. Commit; rerun verify after final commit and record final verification result without dirtying tracked files (runtime evidence ignored).

**Files:** `scripts/verify.sh`, `scripts/smoke.mjs`, `scripts/check-policy.mjs`, final docs/progress.

**Acceptance:**
```bash
bash scripts/verify.sh
bash scripts/verify.sh
git diff --check
git status --porcelain
```
Expected both runs exit0 and last line `VERIFY herdr-dashboard PASS`; status has no tracked/untracked project changes (ignored artifacts permitted); evidence JSON `ok:true`, skippedTests0 and named integration surfaces all passed. External optional capability gaps can remain only under the supported degraded-state contract.

**Done:**

- [ ] All16 milestones logged/committed.
- [ ] Independent script twice green.
- [ ] No required test skipped.
- [ ] Live gaps disclosed.
- [ ] Commit `chore: finalize reproducible dashboard verification`.

## 4. Test strategy and final verifier

Unit tests use fake clocks and safe synthetic data for schemas, percentages/left-used direction, time parsing/DST ambiguity, alert thresholds, identity/dwell, scheduling, redaction, and config. Integration tests use actual Node HTTP + SQLite, temporary git worktrees, a fake herdr **Unix socket**, and Python-spawned fake CLI **PTYs**. Unit fakes do not substitute for these integration surfaces. The optional real tmux smoke does not count as a skipped required test when tmux is absent: command protocol/fixture coverage remains mandatory and a capability gap is recorded. Live quota diagnostics are outside deterministic completion and never automatically enabled by tests.

Playwright Chromium headless tests the **built production** UI and API on loopback: quotas, expiry/eligibility, source failures, stale values, git details, filters, keyboard, themes, viewport, reduced motion, read-only requests, no network egress. One worker, retry0 locally; CI may retry1 but any flaky first attempt is recorded. Screenshots are fixture-only. No screenshot of a real CLI/account. Browser dependencies must exist; otherwise record a runtime blocker, not a pass.

Implement `scripts/verify.sh` as executable Bash with this exact high-level sequence and environment contract. This is a script specification inside the plan; it must be created by the executor, not assumed to exist now.

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
node scripts/preflight.mjs --require-core
export CI=1 TZ=UTC HERDR_FIXTURE=1 HERDR_ALLOW_NETWORK=0
export HERDR_FIXTURE_NOW=2026-09-29T16:00:00.000Z
export HERDR_STATE_DIR
HERDR_STATE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/herdr-verify.XXXXXXXX")
verify_pid=''
cleanup() {
  if [ -n "$verify_pid" ]; then
    kill "$verify_pid" 2>/dev/null || true
    wait "$verify_pid" 2>/dev/null || true
  fi
  rm -rf -- "$HERDR_STATE_DIR"
}
trap cleanup EXIT INT TERM
mkdir -p .artifacts/verify
npm ci --no-audit --no-fund
.venv/bin/python -m pip check
npm run check:policy
npm run check
npm run test:e2e
node apps/server/dist/main.js --fixture --host 127.0.0.1 --port 14317 \
  > "$HERDR_STATE_DIR/server.log" 2>&1 &
verify_pid=$!
node scripts/smoke.mjs --base-url http://127.0.0.1:14317 \
  --wait-ms 15000 --evidence .artifacts/verify/smoke.json
curl --fail --silent --show-error http://127.0.0.1:14317/api/health \
  > "$HERDR_STATE_DIR/health.json"
node --input-type=module - "$HERDR_STATE_DIR/health.json" <<'JS'
import fs from 'node:fs';
import assert from 'node:assert/strict';
const h=JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
assert.equal(h.status,'ok'); assert.equal(h.readOnly,true);
assert.equal(h.mode,'fixture'); assert.equal(h.schemaVersion,1);
JS
node scripts/check-policy.mjs --artifacts .artifacts/verify
printf '%s\n' 'VERIFY herdr-dashboard PASS'
```

`preflight --require-core` checks installed Node/Python/.venv pyte and Chromium availability; never silently installs system packages. Venv/npm/Chromium preparation is documented in README and handoff. `smoke.mjs` polls health every100ms to deadline, fails on premature child exit or malformed response, verifies provider values and window applicability, full banked inventory, actual fake-collector provenance, sessions/loop/worktrees, expected alerts, unknown API404, mutations405, hostileHost403, correct content-type/cache/CSP, SSE first event + heartbeat, and writes sanitized evidence with checks, durations and statuses. Assert evidence does not contain raw screen or secret sentinel. Port14317 must be free; fail clearly on EADDRINUSE without killing its owner. Playwright gets its own port14318 and separate temp DB; do not reuse an arbitrary existing server. Helpers own/reap descendants; stdout banners appear only after all assertions succeed. `HERDR_ALLOW_NETWORK=0` is an enforced command/HTTP policy in fixture composition, not a decorative environment variable.

## 5. Risks, blockers, and completion boundary

- **CLI TUI/version drift:** read installed help and use explicit profile fixtures. Unsupported versions show source unsupported. Add profile only when slash commands and safe startup behavior can be reproduced. Do not silently relax empty-prompt checks to get live numbers.
- **CLI not installed or logged in:** implement/test the adapter with the fake PTY interface; record installed version/missing capability/reproduction command without private paths or account identifiers. Do not run login or read credential caches. Normal dashboard still works with unknown usage cards.
- **Codex banked inventory hidden behind an action:** opening a redemption screen is permissible only when a verified profile proves it cannot consume a reset; never confirm. Otherwise inventory unknown with source limitation. Synthetic end-to-end evidence still must cover all banked fields and alerts; do not claim live inventory integration validated.
- **Startup hooks/plugins/MCP:** a blank CLI can execute global configuration. Unless a documented profile suppresses these startup behaviors, disable that live probe and record why. A TUI status command alone is not a sufficient safety guarantee.
- **Loop observability:** `/goal` in an interactive session is not in OS argv. Herdr status and optional fresh manifests expose known state; bare processes stay unknown. V1 does not promise to introspect every CLI's internal goals or background job scheduler.
- **Dates/percent semantics:** unknown scope, DST fold, bare percentages, quota type confusion fail to unknown. Reset timestamps crossing now make capacity stale/unknown until a fresh CLI observation confirms the reset; never reset usedPercent locally to0.
- **Node SQLite/runtime:** isolate SQL sync calls to tiny bounded batches. If node:sqlite unavailable under actual supported Node, fix runtime pin or record blocker; do not swap to a native addon without documented compatibility evidence.
- **Git safety and privacy:** observe explicit allowlisted roots; count work only, redact short commit subjects, do not inspect .env/config/diff content, do not fix permissions with global safe.directory. Unreadable roots become source problems.
- **Memory/process leaks:** hard time/output/SSE limits, bounded retention, shutdown tests; no orphan PTYs and no unrelated process kills.
- **Dependency/browser access denied:** one bounded retry and record exact failure; continue documentation/unit work independently. Completion still requires all mandatory tests and build. Do not print a successful verifier result without browser execution.

Each `BLOCKERS.md` item has ID, capability, category external-capability/core-runtime/implementation, safe reproduction command, observed sanitized reason, implemented fallback, affected tests, and resolution status. External-capability gaps are permitted only when the live adapter exists, deterministic integration tests cover it, and the UI reports the gap honestly. Core-runtime and implementation gaps prevent completion. Completion means all16 milestone requirements implemented and committed, required tests actually executed without skips, built localhost product demonstrated, and independent `bash scripts/verify.sh` exits0 with its exact success line. It does not assert real-account data when access was unavailable.
