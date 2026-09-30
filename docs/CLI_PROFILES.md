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
| `Redeem reset` (wins even if a prompt is also visible) | `redemption_prompt` |
| `trust this folder` or `trust this workspace` | `trust_prompt` |
| `Sign in` or `log in` | `login_required` |
| `Select a model` | `model_prompt` |

Startup flags that enable plugins, hooks, or MCP are rejected. If those startup behaviors cannot be proven inert, the profile is not launchable.

## fixture-v1

This is the only launchable profile. It accepts version `fixture-1.0.0` exactly, not the rest of the 1.x line. The command is `/usage`. A later screen that contains `Session`, `% used`, and `Weekly` is recognized. The percentages themselves are not copied into the transport JSON; provider parsers consume fixture screens separately.

`tests/helpers/fake-cli.py` is a synthetic TTY program. It is not Claude, Codex, or Grok, and a passing probe against it is not a logged-in account.

## Claude, Codex, and Grok

| Provider | Intended read | Launch |
| --- | --- | --- |
| Claude | `/usage` for the 5h window, the weekly window, and any model-specific weekly label | refused: `profile_unsafe` |
| Codex | `/status` for 5h and weekly quota; `/usage` only for a later inventory screen that cannot redeem on open | refused: `profile_unsafe` |
| Grok | `/usage`; weekly when labeled; 5h is not applicable unless that version prints a real 5h window | refused: `profile_unsafe` |

Live launch stays off because global startup hooks and MCP cannot be shown to be inert. The dashboard does not start a real `claude`, `codex`, or `grok` process to discover that. A future profile may opt in only with version-exact fixture evidence and a documented inert startup.
