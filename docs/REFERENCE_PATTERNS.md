# Reference patterns

Inspection only. Nothing under the reference root is modified. Hashes are the HEAD values read on 2026-09-29.

| Repository | HEAD | Paths used |
| --- | --- | --- |
| herdr-manager | `ef7529edad702320e89cca492dff365131e2ee6e` | `README.md`, `Sources/HerdrManagerCore/Domain/Types.swift`, `Sources/HerdrManagerCore/Adapter/HerdrAdapter.swift`, `Sources/HerdrManagerCore/Adapter/NDJSONClient.swift`, `Sources/herdr-manager-mcp/HerdrManagerMCP.swift`, `Sources/HerdrManagerCore/Usage/TokenMeterTypes.swift`, `Sources/HerdrManagerCore/Usage/TokenMeterReader.swift` |
| FinanceVisibilityApp | `bd123a1c529b02031741c1d2d1713df49047a588` | `README.md`, `finance_analyzer/web/server.py` |
| project-relay | `a8a6313597d7304512a524caedb958f142f0032a` | `README.md`, `docs/PRIVACY_MODEL.md` |
| chhaya-digital-website | `f8d16993187bebfc77d4d6777b259ca734a152d1` | `chhaya-digital/css/styles.css`, `chhaya-digital/css/fonts.css` |
| Bean-Brawl | `711ba9baf4371c7ea3f89d4aa204f4374071f881` | `AGENTS.md` (offline-test expectation only; file not copied) |
| rakazo | `31315c1c8bf2801923a1f017795f9979495f7440` | `AGENTS.md` (offline-test expectation only; file not copied) |

## Patterns carried forward

- Shepherd is the macOS companion. This app speaks to the herdr socket as another read-only client. Baseline noted from the Shepherd tree: herdr 0.7.5 / wire protocol 17.
- `agent.list` is authoritative. `session.snapshot` contributes labels. Requests are `{id, method, params}` NDJSON, not assumed to be JSON-RPC 2.0 envelopes. Added fields are tolerated.
- Internal service names `herd.overview`, `agent.list`, and `agent.inspect` describe reads. `agent.answer`, `agent.say`, `agent.stop`, and `session.spawn` are excluded. V1 does not expose an MCP wire server.
- Shepherd token-meter hour/day/week/month estimates are not subscription quota and are not shown on quota cards.
- The finance app's loopback server plus local SQLite is the operating pattern. Its visual style is not reused.
- Project Relay's local-first boundary is adopted by removing external actions entirely.
- Chhaya Digital paper/ink tokens, flat borders, and the Source Serif 4 / Schibsted Grotesk / IBM Plex Mono pairing are the visual source. Font files are copied with upstream license notices when the UI milestone lands. If those notices cannot be retrieved, the UI falls back to system stacks.
- Tests state what headless evidence proves. A fixture run is not a live-account result.

## Read mapping

| Shepherd / MCP read concept | Linux dashboard |
| --- | --- |
| `agent.list` | Unix-socket method `agent.list` |
| `session.snapshot` | Unix-socket method `session.snapshot` (labels and cwd only) |
| `herd.overview` / `agent.inspect` | In-process snapshot assembly from those two reads |
| Token meter | Not used for quota |

No herdr write method is implemented.

## Linux socket client

The dashboard is a client of the herdr socket. It is not an MCP server, and it does not start herdr. A collect sends two NDJSON lines, `{id, method, params}`, for `agent.list` and `session.snapshot`. `agent.list` decides which panes are agents. The snapshot contributes workspace, tab, and pane labels plus the wire protocol. Request ids are decimal strings and still match when echoed as numbers. Each read waits inside a 2 second budget, accepts one reconnect, and rejects a frame above 4 MiB. Protocol 17 is the verified baseline. An older protocol is reported as unsupported and a newer protocol is reported as additive. Neither result enables a mutation.

Rows that share a provider, pid, and cwd across herdr and tmux collapse into the herdr row. A missing pid, a missing cwd, or a different provider keeps both rows. A named `HERDR_SESSION` uses the documented `herdr/sessions/<name>/herdr.sock` file when that file stays inside the config directory. An unknown name is reported and the default socket is the visible fallback. The live herdr binary is not required for these checks; the integration test speaks to a private Unix socket.
