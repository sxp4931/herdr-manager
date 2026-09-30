# Review: herdr dashboard (2026-09-30)

A senior-engineer pass over the Grok-built dashboard: server adapters, collectors, scheduler, HTTP/SSE, contracts, storage, probes, the web UI, and the tests. The dashboard stays read-only and loopback-only. No endpoint, control, or feature flag was added that could write, act on an agent, or bind off loopback.

`bash scripts/verify.sh` ends with `VERIFY herdr-dashboard PASS`. No check was removed, skipped, or loosened. Counts after this pass: 70 unit tests, 54 integration, 30 Python, and 16 Playwright. Before it: 58 unit, 50 integration, 29 Python, and 15 Playwright.

Severity scale:
- **High:** crash, data corruption, or a security-boundary gap.
- **Medium:** wrong or misleading data on screen.
- **Low:** robustness, UX, or hygiene.

## Findings fixed

| # | Severity | Area | Finding | Fix | Test |
|---|---|---|---|---|---|
| 1 | High | `http.ts` | `new URL(req.url)` ran unguarded inside the request listener. One malformed absolute-form target (`GET http://[`) threw and **crashed the whole server process**. Any local process could trigger it. | Parse the target defensively and answer 400. A static file stream error now destroys the response instead of surfacing as an unhandled `error` event. | `tests/integration/http-hardening.test.ts` |
| 2 | High | `http.ts` | `redactText` ran over the **serialized** JSON. Its query-string pattern (`[^&\s#]+`) and URL-credential pattern are not quote-aware. A pane label, cwd, or commit subject containing `?token=…` swallowed the rest of the document, and the page could not parse `/api/snapshot` or any SSE frame. | Redact values with the existing `redactOutbound`, then serialize. A final sentinel assertion stays on the payload. | `http-hardening.test.ts` (REST and SSE) |
| 3 | Medium | `scheduler.ts` | `collectSessions` used `Promise.all`. A throwing tmux collector discarded herdr's result, and both health rows kept their last success. | `allSettled`: apply what succeeded and record the failed side as `parse_error / collector_error`. | `tests/unit/scheduler.test.ts` |
| 4 | Medium | `scheduler.ts` | A throwing git or quota collector left the old "Fresh" status on screen until the TTL expired. One quota provider throwing skipped the providers after it. | Write a `collector_error` health row that keeps `lastSuccessAt`. Each provider is collected independently. | `scheduler.test.ts` |
| 5 | Medium | `scheduler.ts` | `publish()` and its listeners ran unguarded inside loops that nothing awaits until shutdown. An exception became an **unhandled rejection**, which terminates Node 22. | Isolate each listener and guard `publish()`. | `scheduler.test.ts` |
| 6 | Medium | `scheduler.ts` | Session rows are kept 24 h after they disappear (for dwell continuity), but the snapshot listed all of them. A closed pane stayed on the page with its last status for a day, and a vanished "working" session suppressed the `window_open_idle` alert for as long. | The scheduler projects only ids from the latest collection. Storage retention is unchanged. `docs/OPERATIONS.md` is updated. | `scheduler.test.ts` |
| 7 | Medium | `command-runner.ts` | The git allowlist let through `log --output=<file>` (writes a file) and `symbolic-ref -d/--delete` (deletes a ref: only the positional count was checked). It also allowed `--exec-path` (redirects git to other helper binaries). The git source never sends these, but this guard is the last line before spawn. | Deny them explicitly. | `tests/integration/probe-boundary.test.ts` |
| 8 | Medium | `probes/probe.py` | `docs/CLI_PROFILES.md` promised fixture profiles only launch `tests/helpers/` programs, but nothing enforced it. `claude-fixture-v1` with the real `claude` binary would have started it, startup hooks included, which is exactly what B-02..B-04 forbid. Latent only: the runtime does not wire probes. | Fixture profiles require an executable in `tests/helpers/`, otherwise `fixture_executable_denied` before any PTY opens. | `tests/python/test_probe.py` |
| 9 | Medium | web `App.tsx`/`api.ts` | The initial fetch could resolve after a newer SSE frame and overwrite it. `EventSource.onerror` was a no-op, so a dead server left old data on screen looking live. | `preferNewer` orders the fetch against streamed frames. The header shows Live / Reconnecting with the snapshot time, and a dropped stream shows a warning banner. | `tests/unit/api.test.ts`, e2e `staleness.spec.ts` |
| 10 | Low | `main.ts` | CLI defaults (`127.0.0.1:4317`) always overrode the config, so its `host`/`port` were validated but ignored. `EADDRINUSE` produced an unhandled `error` event with a stack trace. A scheduler start failure exited 0. Shutdown waited the full 2 s fallback whenever an SSE client was connected. | Flags override the config only when given; the loopback check covers both sources. A listen error prints one line and exits 1, and start failures exit 1. Shutdown closes open connections. | `tests/unit/cli.test.ts` (plus a manual EADDRINUSE and SIGTERM check) |
| 11 | Low | web UI | Layout and UX problems:<ul><li>The agent table was squeezed into a ~300 px column, so words broke mid-word ("Clau de", "Work ing").</li><li>Every time printed twice (local plus ISO) plus the zone name.</li><li>Alerts dumped raw camelCase evidence.</li><li>Source status was a wall of boxes.</li><li>Status relied on bare words.</li><li>Loading and error states were one bare line.</li></ul> | See "UI changes" below. | Existing e2e suite (viewport, keyboard, themes, hostile text), updated where the markup changed, plus the new connection test |
| 12 | Low | web | Dead code: `sourceLine` became unused, and `QuotaCard` had a third copy of `providerLabel`. | Removed, with the assertion moved to `healthLabel`/`reasonPhrase`. | `tests/unit/format.test.ts` |

Screenshots (fixture data, gitignored under `dashboard/screenshots/`) compare `before-*` with `after2-*` at 1440×900 light and dark, 900 wide, and 390×844.

### UI changes

- **Layout:**
  - Provider cards across the top, then the full-width agent table with inline filters and a count.
  - Alerts and source status side by side, worktrees last.
  - "Demo data" is a pill beside the title, which keeps the first agent rows above the fold at 1440×900. PLAN requires this and the e2e suite asserts it.
  - The first agent row ends at about 783 px locally, leaving margin for runners whose fonts are taller. The first push measured 875 px here and 917 px on GitHub's ubuntu-22.04 runner.
  - To get there, the header was tightened and banked-reset eligibility sits on the item's header line when it is a one-word verdict.
  - The filter labels are visually hidden. They are still real `<label>`s and the controls keep their accessible names, and the option text ("All providers", "All statuses") and the search placeholder say what each control does.
- **Times:** one readable America/New_York time, as PLAN.md specifies, inside a `<time datetime>` with the ISO instant as a tooltip. Raw CLI reset text appears only when it could not be parsed into a time. Otherwise it is on the tooltip.
- **Alerts:** a severity tag, a readable kind, and the message, with evidence collapsed behind "Evidence" and shown as labelled, formatted values.
- **Status:**
  - Agent status is a marker with a distinct shape per state plus text, so color is never the only signal.
  - Source status is a compact list with tags; problems get a dashed orange tag and a reason line.
  - Ineligible banked resets are highlighted.
- **Agent rows:**
  - The label with a chevron and the cwd underneath. "Show details for" stays in the accessible name through a visually hidden span.
  - Details are aligned key/value facts beside the worktree facts.
  - SHAs clip to 8 characters with the full SHA kept in the DOM and the tooltip.
- **States:** loading and unavailable panels explain what is happening. Empty states are muted.
- **Accessibility:**
  - The horizontally scrolling table wrapper is a focusable named region.
  - `aria-controls` only points at a rendered row.
  - Tabular numerals are used for times.
  - Existing 44 px targets, focus rings, and reduced-motion handling are kept.
- The Impeccable detector ran over the changed UI files with no findings.

## Deliberately left alone

- **Quota probe pipeline not wired into the runtime.** `quota/source.ts` and `adapters/quota-probe.ts` are exercised only by tests. Passive and live modes report `probes_disabled` / `profile_unsafe`. This is intentional while B-02..B-04 are open, so it is not dead code.
- **`config.timezone` is parsed but unused.** PLAN.md fixes the UI zone to America/New_York and the snapshot contract has no field to carry it. Removing it from the strict config schema would break existing local configs.
- **Git never backs off on failure** (`ok || kind === "git"`). This looks intentional (a failing root should not delay the others), and a test pins it.
- **herdr `enteredAt` continuity when both session identities are null.** The adapter treats null === null as the same occupant, while the repository requires a non-null identity to keep dwell. Both are defensible; the storage rule wins on restart. Left for the owners to decide.
- **herdr `protocol_older` reports `unsupported` but still sets `lastSuccessAt`.** Sessions are still read, so this is arguably right. Not changed.
- **Value-level redaction now also collapses control characters inside values** (for example a newline becomes a space). Schemas already forbid control characters in most fields, so this only affects free-text labels, and it is safer.
- **`dashboard/AGENTS.md` still says "work only on feat/herdr-dashboard-v1; do not push or open a PR."** That rule was for the original Grok build. This review pushed and opened a PR because the user asked for it. The file is unchanged.
- **Brand fonts are named but not vendored** (see `docs/DECISIONS.md`), so the page renders in the fallbacks. Out of scope.
- **Agent table on phones scrolls horizontally inside its region** rather than reflowing into cards. PLAN asks for "accessible table overflow" at 390 px, and the body never scrolls sideways.
- **`.github/workflows/dashboard-ci.yml` and the Swift app** are untouched.
