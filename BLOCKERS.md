# Blockers

Optional live CLIs and tmux are reported by `scripts/preflight.mjs` and do not affect `coreReady`. Open items are external capability gaps only.

## B-01

- ID: B-01
- Capability: live herdr daemon
- Category: `external-capability`
- Safe reproduction: `command -v herdr` prints no path. The dashboard does not start herdr and does not read a user socket during tests.
- Sanitized reason: the `herdr` executable is not on PATH, so no live socket was collected.
- Fallback: a missing socket returns source health `missing` with reason `herdr_unavailable` or `session_unresolved`. A later failure after a successful read returns `stale` and keeps the previous sessions. Deterministic coverage uses a private Unix socket.
- Affected tests: none skipped. `tests/integration/herdr.test.ts` passes against that private socket.
- Resolution: open

## B-02

- ID: B-02
- Capability: live Claude subscription quota
- Category: `external-capability`
- Safe reproduction: `command -v claude` prints a path. The `claude` probe profile is `launch_allowed` false. No diagnostic and no collector starts that binary.
- Sanitized reason: startup hooks and MCP are not proven inert, so the live profile returns `profile_unsafe` before a PTY is opened. Authentication was not checked because the process was not started.
- Fallback: `claude-fixture-v1` reads `tests/helpers/fake-claude.py` on a PTY and parses the synthetic `/usage` screen.
- Affected tests: none skipped. `tests/integration/collector.test.ts` passes against that fake CLI.
- Resolution: open

## B-03

- ID: B-03
- Capability: live Codex subscription quota and banked reset inventory
- Category: `external-capability`
- Safe reproduction: `command -v codex` prints a path. The `codex` probe profile is `launch_allowed` false. No diagnostic and no collector starts that binary.
- Sanitized reason: startup hooks and MCP are not proven inert. The banked screen is also not proven to be inventory-only, so the probe does not open a live submenu that might redeem. Authentication was not checked because the process was not started.
- Fallback: `codex-fixture-v1` sends `/status`, Escape, then `/usage` to `tests/helpers/fake-codex.py`. A redeem, apply, or confirm screen stops the probe without a confirmation key. A synthetic `none` inventory is a known empty list.
- Affected tests: none skipped. `tests/integration/collector.test.ts` and `tests/python/test_probe.py` pass against that fake CLI.
- Resolution: open

## B-04

- ID: B-04
- Capability: live Grok subscription quota
- Category: `external-capability`
- Safe reproduction: `command -v grok` prints a path. The `grok` probe profile is `launch_allowed` false. No diagnostic and no collector starts that binary.
- Sanitized reason: startup hooks and MCP are not proven inert, so the live profile returns `profile_unsafe` before a PTY is opened. A live 5h window was not observed. Authentication was not checked because the process was not started.
- Fallback: `grok-fixture-v1` reads `tests/helpers/fake-grok.py` on a PTY. The synthetic screen marks 5h `not_applicable` and parses the weekly window.
- Affected tests: none skipped. `tests/integration/collector.test.ts` passes against that fake CLI.
- Resolution: open
