# State
- Branch grok/quality-burn-0906
- Clock cancelled; stop only on STOP file.
- Pass #5 complete. `swift` is not available in this environment; tests added but not executed here.

## Progress
| # | Status | Notes |
|---|--------|-------|
| 1 | pass5 | Settings.json load/save capped at 256 KB (no wipe). Cursor blobs scanned as SQLite pointers, refused above 2 MB. Detection hash uses a 64 KB suffix. Event cache still kept for all-time. |
| 2 | pass5 | pane_updated empty pane_id ignored. Snapshot/agent.list drop empty ids. Name maps uniquingKeys last-wins (no Dictionary trap). JSONNumber rejects JSON 17.5. |
| 3 | pass5 | AttentionTriage.counts is the exclusive badge/CLI/MCP tally. Menu bar no longer treats stale silent on done/idle as silence. |
| 4 | pass5 | status/get expire past-deadline rows so a poll cannot present an un-approvable write. Spawn/answer/say re-check writesEnabled immediately before the write. |
| 5 | pass5 | herdmgr uses herdSnapshot (agent.list + labels) so shells are dropped and seq is real. JSON includes state_change_seq. Label events resync. |
| 6 | pass5 | SecretRedactor also covers OpenRouter `sk-or-`, Stripe `sk_live_`/`sk_test_`, and Slack `xox*` tokens. MCP tool results already always redact. |
| 7 | pass5 | Working tree clean. `swift` / `swift test` not available in this environment — tests added but not executed. No push. |

## Log
- 14:14 ET — Pass 5 / item 7: Tree clean on `grok/quality-burn-0906`. No `.build`/DMG artifacts. `swift test` not run (no toolchain). Local commits only. Pass 5 closed.
- 14:13 ET — Pass 5 / item 6: SecretRedactor redacts OpenRouter sk-or- (hyphenated, missed by generic sk-), Stripe sk_live_/sk_test_ (underscores), and Slack xoxb-/xoxp- tokens so MCP inspect/tail cannot leak them.
- 14:12 ET — Pass 5 / item 5: herdmgr loads HerdSnapshot.displayAgents (agent.list + labels) instead of session.snapshot panes, so plain shells are omitted and state_change_seq is real. --json includes seq. workspace/tab events resync the herd so labels stay current.
- 14:10 ET — Pass 5 / item 4: SharedActionStore and ActionStore status/get apply the deadline before returning, so a late poll cannot show pending. MCP session.spawn re-checks writesEnabled after claim; agent.answer and gated agent.say re-check immediately before sendKeys/prompt.
- 14:08 ET — Pass 5 / item 3: AttentionTriage.counts is the exclusive worst-first tally. MenuBarLabel used verdict.isSilent, which counted stale silent on done/idle as badge attention. CLI footer and MCP overview use the same counts.
- 14:07 ET — Pass 5 / item 2: parseEvent ignores empty pane_updated ids. parseSnapshot/parseAgentList drop empty workspace/tab/pane ids. HerdrSnapshot.uniqueNameMap skips empty keys and last-wins duplicates so applySnapshot cannot trap. JSONNumber rejects JSON-decoded 17.5 so it cannot become protocol/seq 17.
- 14:03 ET — Pass 5 / item 1: SettingsStore load/save capped at 256 KB and refuses to overwrite an oversized file. Cursor chat blobs are scanned from the SQLite column pointer (no 2 MB Data copy) and refused above maxCursorBlobBytes. HeartbeatPoller hashes a 64 KB detection suffix. Tests in PolicyTests, TokenMeterTests, DiagnosisTests. Intentional tradeoff: fileEventCache still retains historical events for All-time.
- 13:41 ET — Pass 4 / item 7: Tree clean on `grok/quality-burn-0906`. No `.build`/DMG artifacts. `swift test` not run (no toolchain). Local commits only. Pass 4 closed.
- 13:42 ET — Pass 4 / item 6: SecretRedactor redacts OpenAI sk-svcacct- (hyphenated, missed by generic sk-) and GitHub ghu_/ghr_ tokens so MCP inspect/tail cannot leak them.
- 13:41 ET — Pass 4 / item 5: herdmgr --json includes needs_you and priority from AttentionTriage. The footer blocked count uses isActionablyBlocked so gone-on-blocked is not counted twice.
- 13:40 ET — Pass 4 / item 4: SharedActionStore write paths throw fileTooLarge when the on-disk file exceeds 256 KB, so a cap miss cannot wipe live pending actions. DwellTracker.save refuses to overwrite an oversized dwell-state file.
- 13:39 ET — Pass 4 / item 3: diagnoseAll applies a verdict only when status and stateChangeSeq are unchanged, so a silent diagnose cannot land on a pane that finished during the hop. AttentionTriage.isActionablyBlocked is the blocked-count twin of isActionablySilent.
- 13:37 ET — Pass 4 / item 2: parseEvent accepts a top-level pane_id when `data` is missing, and ignores empty pane ids. JSONNumber treats CFBoolean as non-numeric so a JSON `true` cannot decode as protocol 1 or match JSON-RPC id "1".
- 13:35 ET — Pass 4 / item 1: sqliteText refuses columns above 64 KB (Cursor meta hex at 16 KB encoded) before copying into a String. Journal cleanup writes kept lines to a temp file instead of concatenating survivors. Tests in TokenMeterTests + PolicyTests. Intentional tradeoff: fileEventCache still retains historical events for All-time.
- 12:43 ET — Item 1: JSONLLineReader drains lines above 256 KB; BoundedFileRead rejects oversized Grok/Cursor sidecars; HeartbeatPoller.detectionReadLines = 80. Tests in TokenMeterTests + DiagnosisTests. Intentional tradeoff: fingerprint event cache retains historical events so the All-time usage window does not under-count.
- 12:50 ET — Item 2: `health(forProtocol:)` locks unknown/older (writes off) vs verified/newer (writes on). `JSONNumber` accepts NSNumber and Int for protocol/seq. Invalid subscription JSON is dropped instead of throwing out of the event loop.
- 12:52 ET — Item 3: Diagnoser no longer stamps finished agents unclassifiable. AttentionTriage is worst-first (gone/blocked, silent, done); panel Needs-you uses it. Dwell episode resets when status changes even if seq lags. applyRestoredDwell never moves enteredAt forward.
- 12:55 ET — Item 4: Approve/claim of an expired action marks it expired instead of arming a write. MCP re-checks `writesEnabled` after UI confirmation before sendKeys/closePane. PolicyEngine consecutive-answer and cooldown tests added.
- 12:57 ET — Item 5: `herdmgr` missing-socket and connect-failed errors name `HERDR_SOCKET_PATH` / `--socket`.
- 12:59 ET — Item 6: SecretRedactor covers `xai-` and `github_pat_`. MCP `makeToolResult`/`makeToolError` always redact; `agent.say` pending params store redacted text.
- 12:57 ET — Item 7: Tree clean on `grok/quality-burn-0906`. No `.build`/DMG artifacts. `swift test` not run (no toolchain). Local commits only.
- 13:05 ET — Pass 2 / item 1: Token-meter scan no longer concatenates every cached event; Cursor usage is parsed from Data windows; NDJSON framing drops lines above 4 MB (subscription skips, requests fail after drain); waitForShell detection reads are capped at 80 lines. Intentional tradeoff: fileEventCache still retains historical events for All-time.
- 13:08 ET — Pass 2 / item 2: `parseEvent` normalizes dotted subscribe types to underscored wire names so `pane.updated` (nested or flat) drives live updates instead of being ignored. Workspace/tab dotted names map to `.workspacesChanged`.
- 13:12 ET — Pass 2 / item 3: AttentionTriage.isActionablySilent excludes stale silent verdicts on blocked/gone/done/idle. AgentStore.silentCount/blockedCount and MCP herd overview use the same exclusive ranking; gone is no longer counted as working.
- 13:16 ET — Pass 2 / item 4: PendingAction.applyDeadline expires pending/approved and fails executing past expiresAt. Shared and in-memory stores both use it from expireStale/reapStale so a late approve cannot sit armed, and a crashed claim cannot leak forever.
- 13:18 ET — Pass 2 / item 5: `LiveHerdrAdapter.socketHint` is shared by missing-socket, connect, snapshot, and event-stream-ended herdmgr errors.
- 13:22 ET — Pass 2 / item 6: MCP inspect uses the 80-line detection cap; auto-allowed agent.say stores redacted text; JSON-RPC `makeError` redacts; action.status JSON-encodes failDetail so quotes cannot break the tool result.
- 13:13 ET — Pass 2 / item 3 follow-up: MCP agent.list glyphs and sort use AttentionTriage so process-gone is not shown as working.
- 13:14 ET — Pass 2 / item 7: Tree clean on `grok/quality-burn-0906`. No `.build`/DMG artifacts. `swift test` not run (no toolchain). Local commits only. Pass 2 closed.
- 13:20 ET — Pass 3 / item 1: Token scans fold each file into the aggregator instead of concatenating every provider's events. Cursor SQLite meta hex is rejected above 8 KB. Tests in TokenMeterTests. Intentional tradeoff: fileEventCache still retains historical events for All-time.
- 13:24 ET — Pass 3 / item 2: NDJSON response ids match numeric echoes. Subscription `type`/`data` envelopes parse like `event`/`data`. Negative protocol is unknown, not "older". JSONNumber is public for MCP seq decoding.
- 13:27 ET — Pass 3 / item 3: AttentionTriage.priority ignores stale silent on done/idle/blocked/gone. herdmgr status glyphs and blocked/silent counts use the same exclusive ranking.
- 13:31 ET — Pass 3 / item 4: SharedActionStore.pendingActions expires deadline-passed rows before listing. MCP agent.answer seq/index and wait timeouts decode via JSONNumber so NSNumber JSON-RPC values cannot skip the seq gate.
- 13:34 ET — Pass 3 / item 5: socketHint names HERDR_SESSION alongside HERDR_SOCKET_PATH/--socket. herdmgr writes a protocol status line to stderr when health.reason is set.
- 13:36 ET — Pass 3 / item 6: SecretRedactor redacts sk-ant-/sk-proj- (the generic sk- pattern missed hyphens) and GitHub gho_/ghs_ tokens so MCP inspect/tail cannot leak them.
- 13:28 ET — Pass 3 / item 1 follow-up: SharedActionStore and DwellTracker refuse files above 256 KB. Journal cleanup streams lines instead of loading the whole NDJSON file.
- 13:29 ET — Pass 3 / item 7: Tree clean on `grok/quality-burn-0906`. No `.build`/DMG artifacts. `swift test` not run (no toolchain). Local commits only. Pass 3 closed.
