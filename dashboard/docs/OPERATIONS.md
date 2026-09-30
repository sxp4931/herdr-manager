# Operations

The dashboard observes. It does not answer panes, redeem resets, start or stop coding loops, or copy account tokens into this repository.

Fixture mode starts only when `HERDR_FIXTURE=1` and `HERDR_ALLOW_NETWORK=0`. Those fixture collectors serve the synthetic catalog and do not open host git, tmux, herdr, or a usage PTY.

## CLI profile updates

Live probe profiles live in `probes/profiles.py` under the ids `claude`, `codex`, and `grok`. Each has `launch_allowed` false and the reason `startup hooks and MCP are not proven inert`.

Keep `launch_allowed` false until a future change proves that a blank start of that exact CLI version does not run hooks, plugins, or MCP. The proof belongs in version-exact fixture evidence and a dated entry in `docs/DECISIONS.md`. A profile that cannot show that proof stays refused.

Intended reads, once a profile is allowed:

| Provider | Read |
| --- | --- |
| Claude | `/usage` for the 5h window, the weekly window, and a model-specific weekly label when the screen prints one |
| Codex | `/status` for the 5h and weekly windows. `/usage` only for an inventory screen that cannot redeem on open |
| Grok | `/usage`. The weekly window when it is labeled. The 5h window stays `not_applicable` unless that version prints a real 5h window |

The doctor does not start those binaries to learn a version. `node scripts/probe-doctor.mjs --json` reports `present` or `missing`. `node scripts/probe-doctor.mjs --live` reports `profile_unsafe` for a present binary and still executes nothing. Seeing `claude`, `codex`, or `grok` on `PATH` is not a quota reading and is not an authentication result.

Fixture profiles `fixture-v1`, `claude-fixture-v1`, `codex-fixture-v1`, and `grok-fixture-v1` are launchable only against `tests/helpers/fake-cli.py` and the provider fake programs. A passing fixture probe is synthetic. The open live gaps remain B-02, B-03, and B-04 in `BLOCKERS.md`.

Do not paste tokens, auth URLs, home directories, or terminal screens into a profile, a fixture, or a blocker note.

## Banked reset inventory

Banked resets are a Codex field. Claude and Grok use `bankedStatus` `not_applicable` and `bankedResets` null.

A known Codex inventory is an array. An empty array means the screen showed no banked resets. `unknown` inventory is null, not an empty array. `not_applicable` is also null.

The dashboard never sends a confirmation key and never redeems a reset. A screen that says redeem, apply, or confirm stops a fixture probe with an empty keystroke file. The live Codex submenu is not proven to be inventory-only, so B-03 stays open and the live profile is not launched. Synthetic fixtures still cover a known empty list, an expiring reset, and an unusable reset.

## Optional loop manifest

A supervisor may leave `.herdr-dashboard/run.json` inside an allowlisted worktree. The dashboard reads that file when a tmux pane's cwd maps to that worktree. It does not create the file, and it does not instrument an existing loop.

Limits:

- schema version `1`
- maximum 16 KiB
- a symlink that resolves outside the worktree is rejected
- `sessionIdentity` string, 1–120 characters, no control characters
- `provider` is `claude`, `codex`, or `grok`
- `pid` positive integer
- `processStartTicks` nonnegative integer
- `kind` is `goal`, `loop`, `workflow`, `custom`, or `unknown`
- `state` is `running`, `waiting`, `finished`, or `unknown`
- `iteration` nonnegative integer or null
- `objective` string up to 160 characters, or null, with no control characters
- `updatedAt` ISO UTC

The row counts as a manifest loop only when the file is at most 30 seconds old (`updatedAt` age greater than 30 seconds is stale), `pid` and `processStartTicks` match the observed process, and `provider` matches the pane. The file has to live in the worktree mapped from that pane's cwd. A missing, stale, oversized, or mismatched file leaves the loop unknown. `/goal` text inside an interactive session is not read from process arguments.

## Private temp directories

Probe, git, and tmux helpers create a private directory with `mkdtemp` (mode `0700`) and remove it when the observation finishes. The probe child `HOME` is that private directory. The child environment is limited to `PATH`, `HOME`, `TERM`, `LANG`, `LC_ALL`, and the Python isolation flags. API keys and vendor base URLs are not forwarded.

A probe cwd that is world-writable is rejected before launch. The helper does not read shared secret files from the operator home directory.

## Backup, retention, and a corrupt database

SQLite is `node:sqlite` in WAL mode with foreign keys on. The parent directory is mode `0700`. The database file, and `dashboard.sqlite-wal` and `dashboard.sqlite-shm` when they exist, are mode `0600`.

Stop the server with Ctrl+C before copying. Copy the database file and those two sidecars together from the stopped directory (`.local/dashboard.sqlite`, or `$HERDR_STATE_DIR/dashboard.sqlite` when `HERDR_STATE_DIR` is set).

Retention uses the server clock:

- quota samples older than 7 days are deleted
- session and git rows keep the latest observation; an older `observedAt` is ignored
- a session or git worktree that disappears from a later collection is removed after 24 hours. A row last seen exactly 24 hours ago stays until the next collect sees it as older than that
- a session that the latest collection did not report leaves the snapshot and the page immediately. Its stored row stays for those 24 hours so a returning occupant keeps its dwell

`StorageCorruptionError` is raised when the file header is not SQLite, `PRAGMA integrity_check` is not `ok`, or the database cannot be opened. The file is left in place. The server does not delete it and does not create a replacement over the corrupt file. Restore a copy made while the process was stopped, or move the file aside yourself and start again so a new empty database can be created.
