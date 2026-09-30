# CLI profiles

Quota probes run in a new process group, on a new PTY, in an empty private directory. The helper renders the terminal with pyte (160×50) and then discards the screen. Stdout is one JSON object. Stderr is a single reason code. Nothing in that result is a live account quota.

The state machine is `started` → `empty_prompt` → `command_sent` → `known_usage_screen` → `parsed` → shutdown. A trap, an unknown version, or an unrecognized screen stops the probe before any accepting key is written.

Limits: 20 seconds, 512 KiB of PTY output, one probe at a time when `HERDR_PROBE_LOCK` is set. The executable path is absolute and is not looked up on `PATH` again. The child environment is `PATH`, `HOME` (the private directory), `TERM`, `LANG`, `LC_ALL`, and Python isolation flags. API keys, vendor base URLs, `NODE_OPTIONS`, and `LD_PRELOAD` are not forwarded.

## Commands that may be written

Only `/usage` and `/status`, and only when that command is listed on a launchable profile whose empty prompt is an anchored `>` line and whose version is an exact supported string. Prose, `--resume`, `--continue`, `-p`, `--print`, `y` / `Y`, and Enter on a menu are rejected. Escape is valid only for a known probe screen and is not sent by this transport.

## Traps

These screens end the probe with an empty keystroke file:

| Screen text | Reason |
| --- | --- |
| `Redeem reset`, a standalone `Apply`, or a standalone `Confirm` (wins even if a prompt is also visible) | `redemption_prompt` |
| `trust this folder` or `trust this workspace` | `trust_prompt` |
| `Sign in` or `log in` | `login_required` |
| `Select a model` | `model_prompt` |

Startup flags that enable plugins, hooks, or MCP are rejected. If those startup behaviors cannot be proven inert, the profile is not launchable.

## fixture-v1

This transport profile accepts version `fixture-1.0.0` exactly, not the rest of the 1.x line. The command is `/usage`. A later screen that contains `Session`, `% used`, and `Weekly` is recognized. It does not copy the screen anywhere. `tests/helpers/fake-cli.py` is a synthetic TTY program. A passing probe against it is not a logged-in account.

## Provider fixture profiles

These profiles are launchable only against the synthetic programs in `tests/helpers/`. Each accepts the version token `fixture-1` exactly. They are not the live `claude`, `codex`, or `grok` profiles.

| Profile | Program | Commands | Recognized text |
| --- | --- | --- | --- |
| `claude-fixture-v1` | `fake-claude.py` | `/usage` | `Current session`, `% used`, `Weekly` |
| `codex-fixture-v1` | `fake-codex.py` | `/status`, then Escape, then `/usage` | status: `5h limit`, `% left`, `Weekly`; inventory: `Earned resets` |
| `grok-fixture-v1` | `fake-grok.py` | `/usage` | `Weekly`, `% used`, `5h limit` |

Escape is sent only after a recognized status screen, and only to return to the empty `>` prompt before `/usage`. The probe does not press Enter on a menu and does not send `y` or `Y`. A redemption, apply, or confirm screen stops the probe. The keystroke file for the daily Codex fixture is `/status`, Escape, `/usage`.

When capture is enabled, the probe duplicates fd 3 before opening the PTY and writes one NDJSON object per recognized phase: `phase` and `lines` only. That channel is not probe stdout. If fd 3 is closed, the probe still returns its JSON result and simply has nothing to capture. The TypeScript parser (`quota-1`) turns those lines into quota windows and, for Codex, banked resets. It anchors relative times to the injected clock. A New York wall time in the March DST gap or the November fold stays null. `65% left` becomes 35% used. A bare percent stays unknown. Grok without a real 5h reading is `not_applicable`. Codex `none` or quantity 0 is a known empty inventory; a missing or unsafe inventory is `unknown` and null. `earnedAt` stays null unless the screen prints it. The synthetic screens do not.

## Claude, Codex, and Grok

| Provider | Intended read | Launch |
| --- | --- | --- |
| Claude | `/usage` for the 5h window, the weekly window, and any model-specific weekly label | refused: `profile_unsafe` |
| Codex | `/status` for 5h and weekly quota; `/usage` only for a later inventory screen that cannot redeem on open | refused: `profile_unsafe` |
| Grok | `/usage`; weekly when labeled; 5h is not applicable unless that version prints a real 5h window | refused: `profile_unsafe` |

Live launch stays off because global startup hooks and MCP cannot be shown to be inert. The dashboard does not start a real `claude`, `codex`, or `grok` process to discover that. Seeing those binaries on `PATH` is not a quota reading. The open gaps are `BLOCKERS.md` B-02, B-03, and B-04. A future profile may opt in only with version-exact fixture evidence and a documented inert startup.
