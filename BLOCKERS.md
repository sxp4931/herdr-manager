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
