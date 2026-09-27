# herdr-manager Grok EHF loop state

## Passes done

### Pass 1 — in-flight herd snapshots no longer roll a status event back

The menu bar polls `agent.list` every 3s and also refetches on resync, reconnect, and Approve/Deny. Two of those requests can already be in flight when a `pane_updated` or status event lands. `AgentStore` ignored only the first snapshot whose seq was behind that event, then retired the guard. The second snapshot painted the pre-event row, and the next poll alerted again for the same block. The same hole put back a pane the event had removed. A slow pre-event response could also land after a newer poll and replay an intermediate seq.

Each snapshot now carries `currentHerdEpoch`, captured immediately before the request. Every response from before the event keeps that event's pane: status, presence, and dwell. A response that started at or after the event is still authoritative, so a herdr restart or a seq-less wrong event clears on the next poll that started after it. The snapshot that adopts the event keeps its dwell; a later seq bump with the same status starts a new dwell and does not alert again. Callers that omit the epoch keep the old one-snapshot retirement (the existing store tests).

Why this one: a duplicate "needs you" is the menu bar's main signal going wrong, and the interleaving is the normal poll-plus-resync path. The fix stays inside the store's existing seq floor; Shepherd only threads the epoch it already had to capture before `await`.

Files:
- `Sources/HerdrManagerCore/Store/AgentStore.swift`
- `Sources/ShepherdApp/AppModel.swift`
- `Tests/HerdrManagerCoreTests/AgentStoreHerdTests.swift`

Self-review:
- Swift 6: new state lives on `@MainActor` `AgentStore`. The epoch is a `UInt64` captured before the snapshot `await` and passed back. `@ObservationIgnored` so the bookkeeping is not panel state. No new macOS APIs, imports, or signatures that existing callers must adopt (`requestedAtEpoch` defaults to nil).
- Walked the previous nil-epoch cases against the new branches: one stale poll still does not roll a block back, the second nil-epoch poll still corrects a seq-less wrong event, an exited pane stays gone, an event-inserted pane survives one empty poll and drops on the next, and the catch-up poll keeps `enteredAt`.
- With an epoch: two pre-event snapshots (and one that returns after the catch-up poll) do not roll the block back or alert twice; a pre-event seq that sits between the event floor and a newer applied seq does not replay the block; a post-event seq-0 snapshot still corrects a wrong event; two pre-event lists do not resurrect an exit; pre-event empty lists keep an insert and a post-event empty list drops it; an event on one pane does not freeze another pane in the same snapshot; after catch-up, a seq bump starts a new dwell without a second alert.
- Not compiled and not run. No Swift toolchain on this box.

### Pass 2 — overlapping herd reads apply in capture order

Pass 1 orders a read against events. It does not order two reads against each other. The 3s poll, resync, reconnect, and the Approve/Deny re-read can all be in flight with no event between the captures, so they share an epoch. Whichever response was applied last won. A slower read could roll a newer status back (and the next poll would alert again), put a pane back that the later read had dropped, or — if it carried the pre-restart seq and returned last — restore the dead process's row over the restarted herd. Rejecting every lower seq would have fixed the rollback and broken the restart. The later *capture* has to win whether its seq went up or reset.

`AgentStore.captureHerdRequest()` takes the epoch and a new serial together, before the request. `applyHerdSnapshot` drops a serial older than one it has already adopted and leaves the herd, the label caches, and the new-agent lists alone. A later serial still applies a lower seq. Callers that omit the serial keep completion order, which is what the existing store tests do. Shepherd captures on the main actor and enqueues the snapshot on the adapter's serial I/O queue before the `await`, so a later capture does not run `agent.list` first; the serial is the guard for reversed completion.

The same serial covers the write gate. `herdSnapshot(readSerial:)` records the protocol only when the serial is at least the last one recorded, so a slow earlier read cannot put the gate back on the protocol it saw. A connect failure records protocol 0 under its serial: `onIO` clears the reading with no serial, and an earlier read's continuation would otherwise publish the old protocol again. CLI and MCP omit the serial and still always record. Approve/Deny does not send keys from a read whose serial is already behind one the store adopted.

Why this one: backlog item 3, and it is the menu bar's normal overlapping-poll path. Items 1 and 2 stay deferred (below). The fix is a defaulted parameter plus one capture at the existing pre-`await` site.

Files:
- `Sources/HerdrManagerCore/Store/AgentStore.swift`
- `Sources/HerdrManagerCore/Adapter/HerdrAdapter.swift`
- `Sources/ShepherdApp/AppModel.swift`
- `Tests/HerdrManagerCoreTests/AgentStoreHerdTests.swift`
- `Tests/HerdrManagerCoreTests/AdapterTests.swift`

Self-review:
- Swift 6: serial and floor live in `@ObservationIgnored` storage on the `@MainActor` store, and behind `stateLock` on the `@unchecked Sendable` adapter. `HerdRequestStamp` is a `Sendable` struct of two `UInt64`s. New parameters default to nil, so CLI, MCP, and the old store tests keep their signatures. No new macOS APIs. `setLatestProtocol` takes the lock once and returns without calling back into a locked method. `clearProtocolReading` still calls it without holding the lock.
- Walked in capture order: a pre-event serial still loses to the event, the post-event serial still catches up without a second alert, and a later serial with seq 1 replaces seq 9.
- Walked reversed completion: the higher seq that returns first stays, including its title and `enteredAt`; the pre-restart seq 10 cannot come back after idle seq 1; a pane the later read dropped stays gone and does not alert; a nil serial still applies a lower seq and does not move `lastAppliedHerdRequestSerial`.
- Protocol: serial 1 does not replace serial 2; a failed `herdSnapshot(readSerial: 4)` leaves the reading at 0 and serial 3 cannot restore it; an omitted serial still records, then a higher serial replaces that.
- Pass 1's alert helper concatenated `[AgentStatusTransition]` with `[AgentStatusTransition?]`. Those arrays do not add. The optional is wrapped first so the suite type-checks.
- Not compiled and not run. No Swift toolchain on this box.

### Pass 3 — a pane move re-keys the agent instead of leaving the old id in place

herdr's `pane_moved` payload is `previous_pane_id` plus the moved `PaneInfo`. A cross-workspace move assigns a new public pane id and does not emit close or create. The parser kept only the new id. `AgentStore` then looked that id up, found nothing, and left the row on the old id, labelled with the raw workspace and tab ids when the id happened to match. The next poll saw a new pane. A blocked agent alerted a second time, its dwell started over, and Jump focused `AgentID.workspaceId` parsed from the stale id. herdmgr's live table has no poll: after the id change, later status events named a row the table did not have.

The event now carries the previous id, the moved pane, and the label of a workspace or tab the move created. The store and `HerdSnapshot.applying` move the row onto the new id and keep the episode when the status did not change: dwell, verdict, last output. A seq on the moved pane that is behind the stored one does not roll the status back. A real status change still reports a transition, on the new id. A list captured before the move cannot put the old id back or drop the new one; a list captured after adopts the new id and keeps the episode start. The menu bar points the selection at the new id before the store drops the old one. Same-workspace moves, whose id does not change, resolve the tab and workspace through the label cache instead of showing the raw id.

Why this one: backlog items 1–3 stay deferred (below). This one is every cross-workspace move, and it trips the same "needs you" alert passes 1 and 2 were about. The wire shape is the current herdr `EventData::PaneMoved`.

Files:
- `Sources/HerdrManagerCore/Domain/Types.swift`
- `Sources/HerdrManagerCore/Domain/HerdSnapshot+Events.swift`
- `Sources/HerdrManagerCore/Adapter/HerdrAdapter.swift`
- `Sources/HerdrManagerCore/Store/AgentStore.swift`
- `Sources/ShepherdApp/AppModel.swift`
- `Tests/HerdrManagerCoreTests/AdapterTests.swift`
- `Tests/HerdrManagerCoreTests/AgentStoreHerdTests.swift`
- `Tests/HerdrManagerCoreTests/HerdSnapshotEventsTests.swift`

Self-review:
- Swift 6: `HerdrEvent` stays `Sendable`. The new payload is `HerdrAgentInfo` plus strings. Basis updates stay on the `@MainActor` store, in `@ObservationIgnored` storage. `AppModel.retargetSelection` runs on the main actor before `applyEvent`, while the old id is still in the store. No new macOS APIs. CLI and MCP do not switch on the old associated values; the only exhaustive switches are the store and `HerdSnapshot.applying`.
- A request stamp captured before the move has an earlier epoch, so two such lists neither resurrect the old id, nor drop the new row, nor add a second blocked alert. A stamp captured after the move applies the new id and keeps `enteredAt` when status and seq match. The move's seq floor is one past the seq the row kept, and `continuesEpisode` is carried from the status event that opened the dwell, so the catch-up poll does not start a new one.
- Same-id move: tab label comes from the snapshot cache (`wA:t9` → "tests"), not the raw id. New workspace: `created_workspace.label` / `created_tab.label` are cached, and a later `pane_updated` of that pane still resolves them.
- A moved pane whose seq is behind the stored one keeps the stored status and seq and still changes id. A move that actually changes status returns one transition for the new id and starts a new dwell.
- A move to a shell removes the row; a pre-move list does not restore it. herdmgr re-keys in place, so the next `pane_updated` on the new id updates that row, and a layout resync can preserve dwell by the new id.
- Not compiled and not run. No Swift toolchain on this box.

### Pass 4 — agent.answer re-reads the prompt before the keys, and a restart clears the answer cap

MCP `agent.answer` checked `state_change_seq`, then awaited `agent.explain` and a protocol re-read before `sendKeys`. A prompt answered, replaced, or restarted in that gap still received the keys. `PolicyEngine.recordStatusChange` also ignored every `newSeq <= last`, which is right for a stale observation and wrong for a herdr restart: the counter starts over, the pane id is reused, and the 3-answer cap stayed stuck for the life of the MCP process.

The authorizing read now takes a herd-read serial before `await`, and records that serial with the seq and the occupant fingerprint. A serial that is not strictly newer is ignored, so an in-flight read that returns last cannot clear the cap or move the stored episode. A newer serial whose seq went backwards, or whose occupant changed, resets the cap. The same seq and occupant does not. Callers that omit the serial keep the old seq-only rule, which is what the existing policy test locks in.

After explain and the protocol re-read, `agent.answer` reads the herd again and `AnswerSendCheck` refuses unless that pane is still blocked on the same seq and occupant. The refusal uses the same errors as the first check (`Stale state_change_seq`, not blocked, agent not found) plus an occupant change. The confirm read's protocol is the write gate: `health()` with no further await, so a downgrade that read just recorded does not get the keys. A refused send does not count as an answer and does not start the per-agent cooldown. The occupant string moved onto `HerdrAgentInfo` unchanged (`session|…` or `fallback|kind|title|pane`), so pending-action fingerprints stay the same.

Why this one: backlog item 4. Items 1–3 stay deferred. The menu-bar Approve/Deny path already re-reads through `PromptAnswerCheck`; this is the MCP write that did not.

Files:
- `Sources/HerdrManagerCore/Policy/Policy.swift`
- `Sources/HerdrManagerCore/Policy/PromptAnswerCheck.swift`
- `Sources/HerdrManagerCore/Domain/Types.swift`
- `Sources/HerdrManagerCore/Adapter/HerdrAdapter.swift`
- `Sources/herdr-manager-mcp/HerdrManagerMCP.swift`
- `Tests/HerdrManagerCoreTests/PolicyTests.swift`
- `Tests/HerdrManagerCoreTests/PromptAnswerCheckTests.swift`

Self-review:
- Swift 6: the new policy fields stay inside the `PolicyEngine` actor. The serial is a `UInt64` captured on the MCP actor before each herd `await`. `AnswerSendCheck` and `occupantFingerprint` are stateless and `Sendable`. `recordStatusChange`'s new parameters default to nil, so the existing nil-serial tests and any other caller keep the old rule. No new macOS APIs. `health()` was already a synchronous locked read on the `@unchecked Sendable` adapter; the confirm path calls it the same way `connectionState` is called.
- Restart: serial 2 with seq 1 after serial 1 with seq 9 resets a full cap. Serial 1 arriving after serial 2 does not, and repeating serial 2 with a higher seq does not move the stored episode, so a later serial-3 read of seq 5 stays the same episode and stays capped. The same occupant on a newer serial does not reset. A new occupant at the same seq does. A stale serial carrying a new occupant does not.
- Send check: same session, different title, still blocked, same seq, passes (the session id is the occupant; the title is not). A working status, a higher seq, a restarted lower seq, a missing pane, a different session value, and a different kind with no session all refuse. The fingerprint strings match the old MCP formatter, including the nil-title fallback.
- A restart that lands on the same seq and the same occupant fingerprint still does not reset. That observation is indistinguishable from a second look at the same episode, and resetting on equal seq would let a stale read clear the cap. A new session value at that seq does reset.
- Not compiled and not run. No Swift toolchain on this box.

### Pass 5 — a late MCP herd read cannot put the write gate back on an older protocol

MCP runs tool calls concurrently on one adapter. `agent.answer` recorded the protocol under a herd-read serial. Every other herd read, and the write gate's `refreshHealth`, called `setLatestProtocol` with no serial, and a nil serial always applies. A slow `herd.overview`, `agent.say`, revalidation, or gate refresh that had seen protocol 17 could land after a later read recorded a downgrade to 16 and turn writes back on. The connect-failure clear had the same shape: `onIO` forgot the reading with no serial, so an earlier `herdSnapshot` that failed to connect wiped a protocol a later read had already recorded. Pass 2's serial on the failure path could not put that clear back.

`snapshot` and `refreshHealth` take the same optional serial as `herdSnapshot`. A serial behind the floor does not move the stored gate. A refresh that loses the race returns the gate that won, not the protocol its own snapshot carried, so a stale protocol-18 response cannot enable a write after a later read saw 16. A connect failure on a serial-tagged read clears under that serial. MCP captures one serial immediately before every herd read and every write-gate refresh. `agent.answer` still captures its own, because the answer cap records that same id. Callers that omit the serial, including the CLI and the subscription drop, still always record.

Why this one: backlog item 5. Items 1–4, 6, and 7 stay deferred. The menu bar already passed serials on its polls; this is the process where those reads and the write gate share an adapter.

Files:
- `Sources/HerdrManagerCore/Adapter/HerdrAdapter.swift`
- `Sources/herdr-manager-mcp/HerdrManagerMCP.swift`
- `Tests/HerdrManagerCoreTests/AdapterTests.swift`

Self-review:
- Swift 6: the serial is a `UInt64`. `onIO`'s new parameter defaults to nil, so `explain`, `pane.read`, `sendKeys`, and the other request sites keep their calls. `snapshot()` stays the `HerdrAdapter` witness and forwards to `snapshot(readSerial:)`. `refreshHealth()`'s parameter defaults to nil, so the existing tests keep calling it with none. No new macOS APIs. `setLatestProtocol` still takes `stateLock` once and does not call out. The io closure still returns `HerdSnapshot` / `HerdrSnapshot`, both already `Sendable`. MCP's counter stays on the server actor; the capture is the statement before the `await`, which is the same point `agent.answer` already used.
- A herd read, a `session.snapshot`, a refresh that cannot connect, and a refresh herdr answers with an error, each at serial 4, leave a protocol recorded at serial 5 in place. The failed refresh still returns writes off for that caller. A refresh whose snapshot says 18, after serial 5 recorded 16, returns 16 with writes off. Serial 6's failed refresh does clear to 0. A nil-serial `snapshot()` still replaces whatever the floor is holding, which is the CLI's rule. The previous nil-serial reset tests still describe that rule.
- Not compiled and not run. No Swift toolchain on this box.

### Pass 6 — subscribe to pane.moved, and treat a seq-less move as a re-key

Pass 3 re-keys a cross-workspace move. The live socket never asked for the event. herdr's `Subscription::PaneMoved` takes no `pane_id` (safe to subscribe globally; the pane-scoped types are still excluded). A move emits `pane.moved` and does not emit close or create. Without the subscription the handler never ran. Shepherd kept the old id until the 3s poll, and that poll saw a new pane, so a blocked agent alerted again and Jump focused the stale id. herdmgr's live table has no poll, so the row stayed on the old id and later status events updated nothing.

`pane.moved` is now in `globalSubscriptionTypes`. The wire `PaneInfo` has no `state_change_seq`, so every real move parses as seq 0. On the protocol-17 baseline herdr also replays the retained event buffer from sequence 0 when a client subscribes (newer herdr starts the cursor at subscribe time). A seq-less move therefore only re-keys a pane the table already has. It keeps that row's status, seq, and dwell, and it does not insert a pane the snapshot never showed. A created workspace or tab label fills the cache only when that id has no name yet, so a replayed label cannot replace one the last snapshot stored. A move back to a shell still drops the tracked row. A non-zero seq keeps the old rules, including a real status change. A list captured before the move still cannot put the old id back.

Why this one: backlog items 1–7 stay deferred. This is the event pass 3 handled and the socket was not delivering. The seq-less rule is what makes subscribing safe on the protocol-17 replay.

Files:
- `Sources/HerdrManagerCore/Adapter/HerdrAdapter.swift`
- `Sources/HerdrManagerCore/Store/AgentStore.swift`
- `Sources/HerdrManagerCore/Domain/HerdSnapshot+Events.swift`
- `Tests/HerdrManagerCoreTests/AdapterTests.swift`
- `Tests/HerdrManagerCoreTests/AgentStoreHerdTests.swift`
- `Tests/HerdrManagerCoreTests/HerdSnapshotEventsTests.swift`

Self-review:
- Swift 6: no new types, isolation, or macOS APIs. The subscription list is a static `[String]`. The seq check is a local `UInt64` compare on the main-actor store and on `HerdSnapshot`, which is a `Sendable` value type. `if !seqIsMeaningful, let existing` binds the optional `Agent` already in hand. Label-cache writes happen after the untracked-pane return, so an ignored replay does not replace a name the snapshot stored.
- A seq-less payload that says working, for a blocked row at seq 9, re-keys, keeps blocked, seq 9, and `enteredAt`, and does not alert. The snapshot's name for that workspace wins over the event's created label. A list captured before the move does not restore the old id. The next poll, captured after the move, keeps the dwell. The same payload aimed at an id the store does not have inserts nothing and does not plant the created label. A seq-less move onto the id the snapshot already shows does not reopen the episode. A seq-less move to a shell still removes the row. A seq-less move into a workspace the cache does not know uses the created label and still keeps the stored status.
- herdmgr: the same seq-less payload re-keys and keeps the dwell; an unknown pane adds no row. A move that also emits `workspace.created` or `tab.created` still resyncs herdmgr before `pane.moved` is read, which resets dwell (backlog 8). Shepherd does not resync on those events, so the move re-keys first.
- Not compiled and not run. No Swift toolchain on this box.

### Pass 7 — a serial-less connect failure cannot be undone by an earlier herd read

Pass 5 ordered herd reads and the write-gate refresh by the serial captured before the request. `explain`, `pane.read`, `sendKeys`, `prompt`, `focus`, `connect`, and the subscription loop's `clearProtocolReading` still cleared the protocol with a nil serial. A nil serial always records and does not raise the floor, so a herd read that had already started could finish last, write the protocol it saw, and turn writes back on after herdr had stopped accepting connections. The same nil clear wiped a newer reading when it ran last.

Every socket call now takes an epoch under the same lock as its enqueue. A connect failure records protocol 0 under that epoch. A dropped subscription issues its epoch at the drop. An update whose epoch is behind the floor is ignored, including a herd read that carries a newer serial but started earlier. A read that starts afterwards takes a higher epoch and can record. Callers that omit the epoch still always record, which is only the test seam that seeds a reading; snapshot, herd snapshot, and the refresh's error path all pass the epoch from the attempt. A nil herd-read serial still passes the serial gate, so the CLI snapshot keeps recording. A serial behind the floor still loses before the epoch floor moves, which is pass 5.

Why this one: backlog item 5. Items 1–4 and 6–10 stay deferred. The menu bar's Peek and diagnose paths, and MCP's explain, all hit herdr through calls that had no serial. The epoch stays inside the adapter, so Shepherd and MCP do not take a new capture.

Files:
- `Sources/HerdrManagerCore/Adapter/HerdrAdapter.swift`
- `Tests/HerdrManagerCoreTests/AdapterTests.swift`

Self-review:
- Swift 6: the epoch is a `UInt64` next to the existing serial floor, both guarded by `stateLock`. `ProtocolEpochBox` is a private `@unchecked Sendable` class written on the calling task before `onIO` suspends and read only after that call resumes. The enqueue closure does not capture it. `LiveHerdrAdapter` was already `@unchecked Sendable`. No new macOS APIs, protocol requirements, or caller signatures. `setLatestProtocol`'s new parameter defaults to nil.
- The epoch is incremented and `ioQueue.async` is called while `stateLock` is held. `async` returns before the block runs, so the lock is not held across the socket call and a higher epoch cannot be enqueued first. `setLatestProtocol` is not called under that lock. `NSLock` is not recursive; `nextProtocolEpochLocked` is only called by holders of the lock and does not take it again.
- A pane read that fails to connect, after a reading recorded at an earlier epoch, leaves protocol 0. Recording that earlier epoch again, even with a higher herd-read serial, does not restore it. A still-later epoch does. The other direction: a clear whose epoch is the earlier one does not wipe a protocol a later epoch already recorded.
- A herd snapshot and a session snapshot each raise the epoch floor, so a pre-issued epoch cannot replace the protocol they just stored. A refresh that herdr answers with an error does too, and reuses the snapshot's epoch rather than issuing a second one after the failure. A dropped subscription does too. An equal epoch still applies, so the connect-failure clear and the refresh catch can both record 0 for the same attempt.
- A stale herd-read serial still rejects the whole update, epoch included, so a failed read captured earlier does not clear a newer serial and does not move the epoch floor. A nil serial still passes that gate. A nil epoch still passes the epoch gate; after this pass the only nil-epoch caller is the test helper that seeds a reading.
- `recordProtocol` drops an update whose epoch is 0 instead of recording it with no epoch. The enqueue writes the epoch before the socket call, so a real attempt's epoch is at least 1. Dropping is the direction that cannot skip the floor.
- Not compiled and not run. No Swift toolchain on this box.

### Pass 8 — herdmgr keeps dwell when a move's layout refetch adopts the new pane id

herdr emits `workspace.created`, `tab.created`, `workspace.closed`, or `tab.closed` before `pane.moved`, and does not emit close or create for the pane. herdmgr refetches on that layout event. By then `agent.list` already has the new id, so `displayAgents(preserving:)` treated the pane as a new row and started the dwell over. The move then kept that fresh dwell, because the old id was already gone. Shepherd does not refetch on those events, so pass 6's re-key still runs first there. This is the live table, which has no 3s poll to put the episode back.

The table remembers the rows from before the first refetch of a burst. Each `pane.moved` puts that row's `enteredAt` on the new id when the status and seq are still the ones the refetch shows, and the remembered rows stay so every pane in the burst is restored. A second refetch before any of those moves does not replace them: that snapshot is already on the new ids, and storing it would throw away the only copy of the old dwell. A refetch after a move has been applied starts a new burst from the rows as they are. A failed refetch changes nothing. An event that changes some row's id, status, or seq drops the copy, so a seq-less `pane_updated` that opens a new episode without advancing seq cannot be glued back onto the previous one. Focus, and a seq-less update that leaves the episode alone, do not drop it.

Why this one: backlog item 8. Items 1–7, 9, and 10 stay deferred for the reasons below. Holding the pre-refetch rows and rebuilding the table from them was the risk that kept this deferred; the move only copies `enteredAt` onto the refetched row, and only when that row is still the same episode.

Files:
- `Sources/HerdrManagerCore/Domain/HerdSnapshot+Dwell.swift`
- `Sources/herdmgr/Herdmgr.swift`
- `Tests/HerdrManagerCoreTests/HerdSnapshotDwellTests.swift`

Self-review:
- Swift 6: `HerdLiveTable` is a `Sendable` value type. The burst state is private. No actor, no new isolation, no new macOS API. herdmgr mutates the table on the task that already owns the event loop. The public initializer is required; a public struct's memberwise init would be internal. `episodeIdentity` is a local dictionary of `(AgentStatus, UInt64)`, compared by value, and it deliberately ignores `enteredAt` because the reset dwell is what the move undoes.
- A refetch that replaces `wA:p1` with `wB:p4` at the same blocked seq shows the fresh dwell, and the following seq-less `pane.moved` puts the original dwell back, keeps blocked and seq 5, and labels the row from the refetch (`proj` / `scratch`) rather than the move's created-label fallback. The other pane, same id, keeps its dwell. A second refetch before the move does not replace the remembered rows. Focus, and a seq-less `pane_updated` that stays blocked, leave the burst in place so the move still restores. A seq-less update to working drops it, and the move keeps the new episode. A refetch whose seq went from 5 to 6 is not restored. A nil refetch does not arm a burst; the move re-keys the row that is still there and keeps its dwell, using the created label because the snapshot never learned the new workspace. A move to a shell after the refetch dropped the row does not bring it back. Two panes moved by one refetch are both restored. A later burst remembers the rows from after the previous restore, so the next move keeps that dwell rather than a dwell stamped by the intervening refetch.
- The layout event's own redraw can show the reset dwell for one frame. The move is already queued behind the refetch and puts it back on the next event. A refetch that arrives after one move of a burst has been applied starts a new baseline; a following move whose previous id was dropped by the first refetch and is not on that baseline keeps the reset dwell. herdr emits the layout events before `pane.moved`, so the moves of one burst share the pre-refetch rows.
- Not compiled and not run. No Swift toolchain on this box.

### Pass 9 — a mutation waits for the protocol the queue has already recorded

The write gate is a stored protocol. MCP's confirm path refreshed it, then `revalidate` took a newer herd read. That read can record a downgrade or a dead socket. `agent.say`, `agent.interrupt`, `agent.stop`, and `session.spawn`'s split still sent, because nothing looked at the gate again. `agent.answer` already did. The same hole is any caller that checked `health()` and then awaited the write: a herd read enqueued earlier finishes first on the adapter's serial queue and records, and the write was still using the protocol from before that read. Shepherd's Nudge, Close, Jump, and metadata write-back all check, then await.

Mutations now refuse on that queue, after every transaction already enqueued has recorded, and before any byte is written. A refusal is not a connect failure, so it leaves the reading in place. Reads, `agent.wait`, and `connect` are not gated. A verified protocol still sends, and a verified write that cannot connect still clears the reading. MCP's revalidation throws from the herd read it just took, so the confirm-tier tools report that nothing was sent. `session.spawn` checks the placement read the same way. `waitForShell` can clear the gate on a connect failure and then see the shell on a later try; spawn re-reads the protocol before `agent.start` and again before the brief, so a herdr that came back on 17 still launches and one that came back older does not.

Why this one: backlog items 1–7, 9, and 10 stay deferred (below). This is the write the earlier passes ordered the protocol for, still going out after a newer read had closed the gate. The check is one flag on the existing I/O queue, so Shepherd and MCP share it.

Files:
- `Sources/HerdrManagerCore/Adapter/NDJSONClient.swift`
- `Sources/HerdrManagerCore/Adapter/HerdrAdapter.swift`
- `Sources/herdr-manager-mcp/HerdrManagerMCP.swift`
- `Tests/HerdrManagerCoreTests/AdapterTests.swift`

Self-review:
- Swift 6: the refusal runs on `ioQueue`, which already ran the socket calls. The closure captures `self` (`LiveHerdrAdapter` is `@unchecked Sendable`) and calls `health(forProtocol:)` under the existing `stateLock`. The lock is not held across the enqueue: `async` returns, the caller drops the lock, and the block takes it only to read the protocol. `NSLock` is not recursive and this block does not call back into `onIO`. `writes` defaults to false, so snapshot, herd snapshot, explain, pane read, `agent.wait`, and `connect` are unchanged. `NDJSONClientError.writesDisabled` is a new case; the only exhaustive switch is `description`, and `localizedDescription` still forwards to it. No new macOS API.
- A protocol-16 gate refuses sendKeys, prompt, close, focus (agent, workspace, tab, pane), createWorkspace, createTab, split, startAgent, and reportMetadata. Each error is `writesDisabled` carrying the "older than 17" reason, and the stored protocol stays 16. Protocol 0 refuses the same way and stays 0. A herd read that records 16 after a stored 17 refuses the following sendKeys; the fake server would have answered that write with success if it had been sent. Protocol 17 still sends sendKeys, prompt (text and Enter), and close, and the write does not itself change the stored protocol. A protocol-17 close against a missing socket is still `connectFailed` and still clears to 0. A protocol-16 herd read and session snapshot still complete.
- The epoch of a refused write is issued and not recorded. A later snapshot's higher epoch can still store a protocol. A write enqueued before the snapshot that discovers a downgrade still runs: the queue is serial, and that write was ahead of the only observation that knew. Holding it would mean waiting for a read that had not started.
- Not compiled and not run. No Swift toolchain on this box.

### Pass 10 — a moved silence is not announced again

Passes 3 and 6 re-key a cross-workspace move and keep the episode, so a blocked agent does not alert twice. A silence is not a status transition. `SilentAlertLedger` keys the alert by pane id. The move drops the old id, the next diagnosis pass (the 15s loop, or a pass already in flight) sees the new id with the same `since`, and the quiet the user was already told about is posted again. Blocked alerts did not have this hole: a same-status move returns no transition, so `notifyBlocked` does not run.

`retarget(from:to:)` carries the recorded `since` onto the new id and forgets the old one. A later occupant of the old id can alert. A move that has not alerted yet does not invent a suppression, so the first pass still announces that silence once, on the new id. A later `since` still alerts. Shepherd does this after the store accepts the move, and only when the row now at the new id is still actionably silent. A move the store ignored has no row there, so the alert stays on the old id and the next pass drops it. A move that changes status leaves a new episode; pinning the old `since` on it would swallow the next quiet.

Why this one: backlog items 1–11 stay deferred (below). This is the same "needs you" signal the earlier passes protected, on the path those passes did not touch. The menu bar is the only caller.

Files:
- `Sources/HerdrManagerCore/Diagnosis/SilentAlertLedger.swift`
- `Sources/ShepherdApp/AppModel.swift`
- `Tests/HerdrManagerCoreTests/SilentAlertLedgerTests.swift`

Self-review:
- Swift 6: `retarget` mutates the ledger struct. It lives on `@MainActor` `AppModel` next to the store, and the call is synchronous after `applyEvent`, before `notifyAndDiagnoseIfNeeded` schedules a pass. No new type, isolation, macOS API, or signature an existing caller must adopt. `newSilences` is unchanged.
- A silence already announced at `w1:p1` is not announced for `wB:p4` at the same `since`. The old id is no longer tracked, so an agent there with that `since` alerts. A retarget before any alert does not mark the new id, and the first pass alerts once. Retargeting an id onto itself keeps the alert. A new `since` on the new id alerts.
- The app carries the alert only when `AttentionTriage.isActionablySilent` is still true for the new id. A same-status move keeps the silent verdict, which is that case. A status change replaces the verdict, the ledger is not retargeted, and the old id disappears on the next pass. A seq-less move of a pane the store does not have leaves no row, so nothing is carried.
- The notification already on screen still names the old workspace. It is not posted again. herdmgr does not use the ledger.
- Not compiled and not run. No Swift toolchain on this box.

### Pass 11 — a streaming Claude message survives the history fold

Claude writes a message's cumulative usage again on each content line, under one message id, and the later line replaces the earlier one. History compaction folds every linearly priced event before the earliest finite window into one event per session, model, and cwd. A group of more than one event takes a new id. The message id is gone. The next copy, appended after that fold, does not replace anything and All-time counts the message twice: once inside the group, and once as the new line.

The fold now leaves two ids alone: the unterminated last line, which the next read parses again, and the last usage event in file order. That is the message still being appended. A week or month boundary refolds the cache without reading the file; the stored id stays out of that fold too. An append that contains no usage line does not forget it. The older lines in the session still fold, and the all-time sum is the same until a real replacement arrives. A copy of an earlier message, once a newer usage line has been logged, can still be folded and then counted again. An edit of bytes behind the resume point is still unseen.

Why this one: backlog item 12. Items 1–11 stay deferred. This is the usage total going wrong on a live transcript, which is the log the menu bar re-reads every refresh. The id was already on the resume for the tail; the last completed usage line is the same kind of fact.

Files:
- `Sources/HerdrManagerCore/Usage/TokenMeterReader.swift`
- `Tests/HerdrManagerCoreTests/TokenMeterTests.swift`
- `Tests/HerdrManagerCoreTests/TokenMeterAppendOnlyTests.swift`

Self-review:
- Swift 6: `lastEventID` is a `String?` on the private resume value the meter actor already stores. `preservedEventIDs` is a synchronous file-private function and does not touch the actor's state. `compact`'s `keeping` parameter defaults to an empty set, so every existing call still folds every eligible event. No new isolation, macOS API, import, or public signature. The id is recorded while the line is parsed, before compaction appends the folded group, so it is not read back from the reordered array.
- A group of three December events folds the first two and leaves `live` at its own 40 tokens. Replacing that id with 90 leaves one event at 90 and a total of 220, which is the two older lines plus the new cumulative usage. Folding the same three without the id yields one event whose id is not `live` and whose input is 170. Keeping the id does not change the all-time summary.
- The meter path: three terminated December lines total 170 input and 17 output. The next copy of the last message is read as only the appended bytes and totals 220 and 22, matching a meter that reads the finished file from the start. The same three lines dated inside January stay 170 when February's cutoff refolds the cache without reading the file, and the appended copy then totals 220, again matching a fresh read.
- The tail id is still preserved, so an unterminated last line is still replaced rather than folded. Codex and Kimi ids are per line and are not repeated; leaving the last one unfolded changes the event count by one and not the sum.
- Not compiled and not run. No Swift toolchain on this box.

### Pass 12 — a silence ends when output moves its clock

Diagnosis reads each agent once, at the start of the pass, then awaits process and explain calls for the rest of the herd. The heartbeat polls every 10 seconds and writes `lastOutputAt` when the detection screen changes. The pass still stamped `.silent` from the copy it started with, whenever status and seq were unchanged. A pane that had just produced output was notified as quiet, and a quiet already on screen stayed up until the next 15s pass re-measured the clock.

On apply, a silence is measured again against the row as it is now, with the same threshold the pass used. Output inside the threshold leaves the pane healthy. A row that is still quiet keeps that pass's CPU reading and the current clock, so the alert names the later output rather than the copy. Any other verdict is applied as before: a process that left during the read is still gone. The heartbeat's own write does the other half. A newer output time that moves the silence clock clears the quiet immediately. A time that is not newer does not move the clock backward. A time still before the episode does not end a silence measured from `enteredAt`.

Why this one: backlog items 1–13 stay deferred (below). This is the same "needs you" signal the earlier passes protected, on the overlap of the 15s diagnosis pass and the 10s output poll. Both writes are on the store the menu bar already reads.

Files:
- `Sources/HerdrManagerCore/Store/AgentStore.swift`
- `Tests/HerdrManagerCoreTests/AgentStoreHerdTests.swift`

Self-review:
- Swift 6: both updates run on the `@MainActor` store. `silenceOnCurrentClock` is a static function on that class; it uses the verdict value and `Diagnoser`'s nonisolated static clock and threshold. `applyObservedOutput` is the mutation the heartbeat task already performed inside `MainActor.run`. No new protocol requirement, macOS API, import, or signature a caller must adopt. The test double is `@unchecked Sendable` in the same shape as the existing diagnosis-race adapter, and it hops to the main actor before touching the store.
- Output during this pane's read, from twenty minutes quiet to now, leaves the row healthy instead of silent. The same write during an earlier pane's read leaves that pane silent from its own output and clears the later pane, including a silence it was already showing. A clock that moved from twenty minutes to ten is still past five minutes, and the silence is dated at the ten-minute output. An untouched clock stays dated at its output. A bare shell is still process-gone when the clock moves, and the new output time is kept.
- A newer heartbeat time clears a showing silence. An older time changes nothing. Output that is still before `enteredAt` updates `lastOutputAt` and keeps the silence dated at the episode start. Output does not clear process-gone. An id the store does not have is ignored.
- A move that lands while the pass is in flight still drops the verdict: the old id is gone, and the result has no link to the new one. The next pass reads the new id. That stays deferred.
- Not compiled and not run. No Swift toolchain on this box.

### Pass 13 — a crashed pane is counted and marked as gone

herdr leaves `agent_status` at working or blocked after the process dies. Shepherd and MCP classify that with the process list. herdmgr never did, so a dead agent stayed a green working row (hidden from the default table) or a red blocked row. The footer already omitted gone: `AttentionTriage.counts` had stopped counting a crash as blocked, and nothing put it in the summary. MCP's overview did count gone, then drew it with the same red circle as a permission prompt, and a crashed `unknown` pane was also added to the unknown total.

The exclusive bucket is now one function. A crash's text mark is `GONE`; blocked stays the red circle. The footer is `blocked | gone | silent | done`. herdmgr `--json` adds `attention` with that bucket, so a blocked crash is not the same record as a live prompt. MCP's row mark and overview chips use the same marks, and its idle/unknown totals use the same bucket, so a crash is not counted twice.

herdmgr reads the process list before the first paint, after every event, and on a 15s tick (a dead process often emits nothing). A running read clears a crash back to the status verdict. A failed or empty read does not. A same-status pane update keeps the crash, because that event is how herdr says "still working" over a dead process. A status change clears it, and the read before the next paint stamps it again if the shell is still bare. A layout refetch keeps the crash for the same episode; `pane.moved` puts it on the new id with the dwell. Silence is not classified on this table: there is no output clock, and the 5-minute threshold would call a busy agent quiet.

Why this one: backlog item 16. Items 1–15 stay deferred (below). The count existed and the table could not say which red it was, because the CLI never made the reading.

Files:
- `Sources/HerdrManagerCore/Domain/AttentionTriage.swift`
- `Sources/HerdrManagerCore/Diagnosis/Diagnoser.swift`
- `Sources/HerdrManagerCore/Domain/HerdSnapshot+Dwell.swift`
- `Sources/HerdrManagerCore/Domain/HerdSnapshot+Events.swift`
- `Sources/herdmgr/Herdmgr.swift`
- `Sources/herdr-manager-mcp/HerdrManagerMCP.swift`
- `Tests/HerdrManagerCoreTests/AgentStoreHerdTests.swift`
- `Tests/HerdrManagerCoreTests/DiagnosisTests.swift`
- `Tests/HerdrManagerCoreTests/HerdSnapshotDwellTests.swift`
- `Tests/HerdrManagerCoreTests/HerdSnapshotEventsTests.swift`

Self-review:
- Swift 6: `ProcessGoneObservation` is a Sendable enum. `observeProcessGone` is on the existing `Diagnoser` actor and only reads. `HerdLiveTable.applyProcessGone` mutates the table on the calling task. herdmgr does not pass the table `inout` across an `await`: the reads return, then the stamp runs. The event task and the 15s tick share an `AsyncStream` of a Sendable wake; neither touches the table. `LiveWake` is Sendable. No new macOS API. `statusMark`'s working override is a defaulted `String`, so the CLI keeps green for working and MCP keeps yellow. `counts` now switches on `kind(for:)`, which is the old ladder including idle and unknown as untallied.
- A blocked or working row whose foreground is only `zsh` is `gone`, mark `GONE`, and the footer names it. The same row with `node` in front is running and is not marked gone. An empty list or a thrown read is `unknown` and leaves a crash in place; it does not clear one and does not invent one. Done does not ask for the process list. A running read of a crashed blocked row restores the status verdict and leaves the other row's permission prompt alone.
- A same-status `pane_updated` or status event keeps the crash and its dwell. A status change clears it. A same-episode refetch keeps it; a status change in that refetch does not. After a layout refetch the new id is not gone yet, and `pane.moved` puts the pre-refetch crash on that id with the original dwell. The other pane is not marked gone.
- The move copies the pre-refetch crash even when a read between the refetch and the move had already seen the agent running. herdmgr reads again after the move, before it paints, and that running read clears it. A failed read leaves the copied crash, which is the direction that does not hide one.
- Not compiled and not run. No Swift toolchain on this box.

### Pass 14 — a moved pane keeps the screen the heartbeat already hashed

Passes 3 and 6 re-key a cross-workspace move and keep the episode. Pass 10 carries a silence already announced onto the new id. Pass 12 ends that silence when output moves its clock. The heartbeat is what moves the clock, and it hashes the detection screen by pane id. The move drops the old id. The next poll of the new id is a first look: it stores the screen and does not report it. Output that arrived with the move, or in the gap before that poll, never reaches `lastOutputAt`. The pane stays on the old clock and can be notified as quiet after it has already produced output. The same miss happens when the new id already had a hash: that screen belonged to the pane that was there before, so the mover's unchanged screen is reported as new output and a showing silence is cleared.

`retarget(from:to:)` moves the hash and the poller's output date onto the new id, and forgets the old one. A mover that has not been polled yet does not take the destination's hash, so the next poll is a first look instead of a comparison against someone else's screen. Shepherd does this after the store accepts the move, and only when the row now at the new id is the pane that left the old one. A move to a shell, a same-id move, and a move the store ignored leave the hashes alone. The old id disappears on the next prune.

Why this one: backlog items 1–17 stay deferred (below). This is the same "needs you" signal the earlier passes protected. The menu bar is the only caller; herdmgr does not hash detection screens.

Files:
- `Sources/HerdrManagerCore/Diagnosis/HeartbeatPoller.swift`
- `Sources/ShepherdApp/AppModel.swift`
- `Tests/HerdrManagerCoreTests/DiagnosisTests.swift`

Self-review:
- Swift 6: `retarget` mutates the poller actor. `AppModel` is `@MainActor` and awaits that call after `applyEvent`, before the next event. The target is a pair of `AgentID`s captured while the old id is still in the store. No new type, macOS API, import, or signature an existing caller must adopt. The test script is an `@unchecked Sendable` class behind a lock, the same shape as the existing read-lines log. `MockHerdrAdapter` stays a value type.
- The id the poll started with is captured before the read. A retarget that lands while that read is in flight still records on the old id, and the next poll of the new id compares against the hash the retarget saved. A screen that changed during the read is reported on that next poll. It is not stored as the new baseline.
- A hash of "one", then "two", then a move: the new id's next "two" is not a change, and the "three" after it is. The old id no longer has a date. A baseline of "one" and a move onto "two" reports "two" for the new id. A destination that had already hashed "other" does not call the mover's "alpha" a change; "beta" is. A mover with no hash clears the destination hash, so "different" is a first look and not a change. Retargeting an id onto itself still reports the following change. Prune after the retarget drops the old id and keeps the new one.
- The event loop only calls retarget when the old id was in the store, the payload names an agent, the id changed, and the row is on the new id afterwards. A seq-less move of an untracked pane, a same-id move, and a move to a shell do not. A read already queued against the old id can still write that id's hash back after the retarget; the following prune drops it, and the new id keeps the hash from before that read.
- Not compiled and not run. No Swift toolchain on this box.

### Pass 15 — a poll that already shows the moved pane keeps the episode

The request socket and the event socket are separate. A 3s poll captured after a cross-workspace move can be applied before `pane.moved` is read. The new pane id is not in the store, the old one is absent from that list, and nothing ties them together. The row starts over. A blocked agent alerts again, its dwell and last output are dropped, and the selection, silence alert, and detection hash stay on the id the poll already removed. Passes 3, 6, 10, and 14 only follow the move once the event is the thing that re-keys.

`agent.list` carries `agent_session`. The value is the occupant; the pane id is not. When a snapshot drops exactly one pane with a session value and introduces exactly one new pane with that same value, the new row continues the old one: same status and seq keep dwell, verdict, and last output and do not alert. A status change alerts once, from the old status, on the new id. A seq that went backwards still does not alert blocked again — that is the same rule as a restart that kept the pane id — and it does start a new dwell. An empty session value is not an identity. Two panes sharing a value, or a value that is still listed, do not match. The old id is tombstoned so a list from before the poll cannot insert it beside the row that continued. The menu bar reads those moves before it awaits anything else: selection and a silence already announced follow immediately, and the detection hash moves with them. `pane.moved` arriving afterwards still re-keys. If the poll already took the row, the hash is only filled when the new id does not have one yet, so a screen that poll already hashed is not reported again.

Why this one: backlog items 1–17 stay deferred (below). This is the same "needs you" alert those passes closed, on the interleaving they did not: the poll wins the race with the event. Panes with no session value still split; matching them on kind and title would glue two agents together.

Files:
- `Sources/HerdrManagerCore/Store/AgentStore.swift`
- `Sources/HerdrManagerCore/Diagnosis/HeartbeatPoller.swift`
- `Sources/ShepherdApp/AppModel.swift`
- `Tests/HerdrManagerCoreTests/AgentStoreHerdTests.swift`
- `Tests/HerdrManagerCoreTests/DiagnosisTests.swift`

Self-review:
- Swift 6: the session map and `sessionMoves` are `@ObservationIgnored` storage on the `@MainActor` store. The identity helper is `nonisolated` and only reads the `Sendable` info value. `applyHerd` is now `async` so it can await the poller; every caller was already in an async task and awaits it. Selection and the silence ledger are updated before that await. The hash retarget is queued on the poller before the event loop can run, because the event loop needs the main actor and this task holds it until the await. No new macOS API. `sessionMoves` is not cleared when an older serial is rejected, and the app does not read it unless the serial was adopted.
- Same session, same seq: the poll keeps blocked, seq 5, the pinned dwell, last output, and the silent verdict, labels the new workspace from the snapshot, and returns no transition. The other pane's dwell is untouched. The seq-less move that arrives next does not reopen the episode or replace the snapshot's label. An earlier serial that still names the old id is dropped. A later seq bump on the new id starts a new dwell and does not alert.
- A working → blocked change on the new id alerts once, `from` the old status, on the new id. Two different sessions in one poll each keep their own dwell. A different session alerts as a new pane and does not keep the silent verdict. No session, and an empty session value on two panes, both alert from nil and start a new dwell. A session that is still listed is not carried onto a second pane. A seq of 9 then 1 on the new id does not alert blocked again, starts a new dwell, and keeps last output. A seq-less move carries the session, so a later poll onto a third id keeps the dwell.
- Vacant hash retarget: an unpolled new id keeps the origin's screen, so the same screen is not a change and the next one is. A new id that was already hashed keeps that hash. An origin that was never hashed does not clear the destination.
- Not compiled and not run. No Swift toolchain on this box.

### Pass 16 — a heartbeat change compared on the old id still moves the silence clock

The heartbeat hashes the detection screen by pane id. A change is returned under the id the poll started with, and the store writes `lastOutputAt` under that key. Passes 3, 6, 14, and 15 re-key a cross-workspace move and carry the hash, so the next poll does not treat the mover's screen as new output. They do not carry a change the poll had already compared. The move can land in the gap after that comparison and before the store applies it: the event loop and the herd poll are the main actor, and the heartbeat is suspended until `poll` returns. The row is already on the new id, the update names the old one, and it is dropped. The hash that moved is the new screen, so the next poll does not report it either. `lastOutputAt` stays on the previous output. A pane that just produced output can be notified as quiet, and a quiet already showing stays up.

The poll now parks a change it compared against that pane's own previous screen, separate from the date a first look stores. `retarget` and `retargetVacant` hand the parked time to the new id and return it. The menu bar writes that time onto the row after the move. A later hop still has it, so a second move in the same gap does not drop it. A first look returns nil: that time is "when we first stored the screen," and writing it would end a silence the screen never moved. A vacant fill keeps the later of the two parked times for the hop after this one, and still returns the origin's time so the comparison the old id made is not lost when the new id already has a hash. Prune drops a parked change for an id that left. The poll's own dictionary is unchanged, so a row that has not moved still updates the way it did.

Why this one: backlog items 1–18 stay deferred (below). This is the same "needs you" signal those passes protected. The hash already followed the move; the clock the silence is measured from did not. The menu bar is the only caller.

Files:
- `Sources/HerdrManagerCore/Diagnosis/HeartbeatPoller.swift`
- `Sources/HerdrManagerCore/Store/AgentStore.swift`
- `Sources/ShepherdApp/AppModel.swift`
- `Tests/HerdrManagerCoreTests/DiagnosisTests.swift`

Self-review:
- Swift 6: `outputChanges` is actor state on `HeartbeatPoller`, next to the hash map. `Date` is `Sendable`. Both retargets return `Date?` and are `@discardableResult`, so the existing call sites and tests keep compiling. `parkOutputChange` is a synchronous method on the actor; it does not hop and it does not touch the hash. `applyObservedOutput` was already `@MainActor` on the store; it is now `public` so the menu bar can pass the carried time. No new macOS API, import, or protocol requirement. The event-loop `switch` assigns the optional on both kinds before it is read.
- A baseline retarget, and a vacant retarget of that same baseline, return nil. A screen that changed from "one" to "two" returns that poll's date, the old id's baseline date is gone, and a second retarget returns the same date on the third id. Applying the poll's dictionary to the old id leaves a silent row on the new id silent; applying the carried date clears it and sets `lastOutputAt`. A vacant retarget after the new id has already hashed "two" still returns the change, and the next read of "two" is not another change. Prune of an id that left makes the following retarget return nil.
- A read that is still in flight when the hash is moved does not park a change. The hash it sees on return is gone, so it stores a first look on the old id, and the new id keeps the hash from before that read. The next poll reports a screen that actually changed. Carrying the in-flight bytes would treat whatever now occupies the old pane as the mover's output (item 19).
- A result the poll already returned for the new id is still applied under that id. When the poll landed first, that screen is the mover's. Replace drops a parked change on the destination so a later hop does not carry a previous occupant's time; the dictionary this poll already built is not rewritten.
- Not compiled and not run. No Swift toolchain on this box.

### Pass 17 — an approved write follows the session when the pane id moves

Approve, Deny, and the MCP tools that wait for a person (`agent.say`, `agent.interrupt`, `agent.stop`, and a split `session.spawn`) hold a pane id across a re-read. A cross-workspace move assigns a new public id. The occupant fingerprint includes that id, so the re-read called the agent gone and the approved write never ran. The prompt was still blocked on the same seq, on the new pane. `agent.answer` already refuses this on purpose: its 3-answer cap was recorded against the id the authorize read used, and the explain gap is short. The confirmation wait is up to two minutes, and the panel's Approve click re-reads before the keys.

When the approved pane id is no longer an agent, and exactly one listed pane has that session, the write goes there. Status and seq still have to match, so a new prompt, a restart, or a status change refuses. An empty session value is not an identity. Two panes sharing a value match nothing. A fingerprint with no session does not follow. A pane id that is still listed is never redirected: whoever is there now is compared to the approval. The panel copies the session off the store before the re-read, because a move that lands during that read takes it off the old id. A second click on the new row is ignored while that session's response is still in flight. Split uses the successor's pane, workspace, and cwd.

Why this one: backlog items 1–19 stay deferred (below). This is an approval the user already gave, dropped because the id moved. The session value is the same occupant pass 15 uses to keep the episode. The answer cap is the reason `agent.answer` does not follow.

Files:
- `Sources/HerdrManagerCore/Policy/ConfirmedPaneFollow.swift`
- `Sources/HerdrManagerCore/Policy/PromptAnswerCheck.swift`
- `Sources/HerdrManagerCore/Domain/Types.swift`
- `Sources/HerdrManagerCore/Store/AgentStore.swift`
- `Sources/ShepherdApp/AppModel.swift`
- `Sources/herdr-manager-mcp/HerdrManagerMCP.swift`
- `Tests/HerdrManagerCoreTests/PromptAnswerCheckTests.swift`

Self-review:
- Swift 6: `ConfirmedPaneFollow` is a `Sendable` enum. The session string is a computed property on `HerdrAgentInfo`. The store lookup is `@MainActor` and the menu bar copies the `String?` before creating the task. `inFlightAnswerSessions` is `@ObservationIgnored`. `addressedParams` is a `nonisolated` static method on the MCP actor. `refusal` gained a defaulted `sessionIdentity`, so existing callers stay source-compatible. No new macOS API.
- Same pane, same session, renamed title: the write stays on that pane. A different session in that pane refuses, and a copy of the old session on another pane is not used. Occupant is checked before seq. A fallback fingerprint whose title changed refuses, and a fallback fingerprint does not follow a gone pane.
- One successor, same status and seq, including a session value that itself contains `|`: the write uses the new pane id. A higher seq and a restarted lower seq both refuse. A status change refuses. Two successors, an empty session value, an empty pane id, and a shell refuse. A shell left at the old id does not hide the one real successor.
- The panel: the store's session for `wA:p1` is `agent|claude|session|abc`. After the re-read shows only `wB:p4`, Approve addresses `wB:p4`. Without the captured string it refuses. A move clears the old id's session, which is why the copy happens before the task. The original pane wins when it is still an agent. A moved session that is working, or whose seq changed, refuses. `agent.answer` still refuses the same session on a new id.
- Not compiled and not run. No Swift toolchain on this box.

### Pass 18 — the answer cap and the write cooldown follow the session

The 3-answer cap and the 10s per-agent cooldown were keyed by pane id. A cross-workspace move assigns a new public id to the same `agent_session`. Pass 17 sends an approved say, interrupt, stop, or split to that new id, and a client that re-lists the herd addresses it directly. Either way the budget on the old id no longer applied: three answers could be followed by three more on the new id, and a write recorded on one id did not cool down the other.

When the caller passes `HerdrAgentInfo.sessionIdentity`, the cap, the episode seq, the herd-read serial, and the cooldown live on that identity. A later check of any pane id with the same identity sees them. A fingerprint that only changed its pane-id suffix is the same occupant, so the move keeps the cap; a different session value, or a lower seq on a newer read, still resets it. A stale serial still cannot clear it. The pane an answer was recorded against keeps a copy of the cap, and the pane a write was sent to keeps the cooldown, so a later check that only has that pane id still refuses. A check that names a session uses the session's own answer count: the next occupant of the id is not stuck with the cap the previous session filled. An empty session value stays on the pane id. Callers that omit the identity keep the old per-pane rule.

`agent.answer` records and checks the session it just read. Confirm-tier `agent.say`, and the gated say, do too. Interrupt, stop, and the say that followed a move record the cooldown on the pane the write actually addressed and on that pane's session. `session.spawn` still records the new pane only; it has no session yet.

Why this one: backlog items 1–22 stay deferred (item 20's reason is updated below). This is the safety limit those writes are counted against, still stored on the id the agent had left. The menu bar does not use the cap. MCP does, on every answer.

Files:
- `Sources/HerdrManagerCore/Policy/Policy.swift`
- `Sources/HerdrManagerCore/Policy/PromptAnswerCheck.swift`
- `Sources/herdr-manager-mcp/HerdrManagerMCP.swift`
- `Tests/HerdrManagerCoreTests/PolicyTests.swift`

Self-review:
- Swift 6: the new key is a private `Hashable, Sendable` enum inside the `PolicyEngine` actor. The dictionaries never leave the actor. New parameters default to nil, so the existing policy tests and any caller that does not have a session keep the pane-id rule. No new macOS API. `checkWriteAllowed`'s free tier still returns before either budget is read. `recordWrite` appends one global timestamp when it stamps both the session and the pane.
- A session capped at seq 5 on `wA:p1` is still capped on `wB:p4` after a newer read of the same seq, including a check of `wB:p4` that omits the session once that read has published the count, and a check of a third id that passes the session. The next session on `wB:p4` is allowed. A session value that only shares the prefix `abc` with `abcd` does not take the cap, and a fingerprint of the longer value resets the shorter session at the same seq instead of matching it. A restart to seq 1 on the new id resets. A read whose serial is older does not. An empty identity does not link two panes.
- A write recorded for the session cools down the new pane id, the pane that was written, and a different session checked against that same pane. Another pane with another session is allowed. Six session-keyed writes, not three, fill the global minute. The pane stamp is why a different session in the pane that was just written waits out the 10s; that wait is the cooldown of the id the bytes went to.
- `agent.answer` still refuses to send when the authorized pane id is gone. The cap follows the session, and the explain that justified the keys does not. Answers recorded before a session value existed stay on the pane id; the first read that has a session starts that session's budget at zero (item 24).
- Not compiled and not run. No Swift toolchain on this box.

### Pass 19 — interrupt, stop, and spawn take a write slot before they send

The 10s per-agent cooldown and the 6/min global cap are `PolicyEngine`. `agent.answer` and `agent.say` checked them. `agent.interrupt`, `agent.stop`, and `session.spawn` only called `recordWrite` after a successful send, so the budget they are supposed to share never refused them. Spawn is auto-allowed: a burst of `session.spawn` created workspaces with no cap. Two overlapping answers could also both pass `checkWriteAllowed`, because that check does not record, and both sends landed before either `recordWrite`. A confirm-tier say checked before the approval wait, which is up to two minutes, and did not check again at the send.

`reserveWrite` is that check and the record in one actor call. A refusal does not record. Free tier does not either. The slot stays taken if the send then fails; putting it back would let a burst of failures through. `reserveGlobalWrite` takes one global slot and no per-agent cooldown, which is the spawn: it has no pane yet. `noteAgentCooldown` cools the pane that actually started and does not count a second time. A check on its own still records nothing.

Answer and a gated say still check before explain or the dialog, then reserve immediately before the bytes. Confirm-tier say, interrupt, and stop check before asking and reserve again after revalidation, on the pane the write addresses. A refusal there marks the claimed action failed, journals `policy_denied`, and does not send. Spawn reserves after the write gate and before it creates anything. The new pane is cooled down only once the agent has started.

Why this one: backlog items 1–24 stay deferred (below). Pass 18 stored the cooldown on the session those writes address. Interrupt, stop, and spawn never consulted it, and spawn has no confirmation wait to slow it down.

Files:
- `Sources/HerdrManagerCore/Policy/Policy.swift`
- `Sources/herdr-manager-mcp/HerdrManagerMCP.swift`
- `Tests/HerdrManagerCoreTests/PolicyTests.swift`

Self-review:
- Swift 6: the new methods are on the `PolicyEngine` actor and do not await. `PolicyResult` and `AuthorityTier` were already `Sendable`. The MCP server is an actor and awaits them. No new type, macOS API, or signature an existing caller must adopt. `recordWrite` still stamps one global timestamp. `globalRefusal` is the prune-and-compare that check already did; it does not append. `reserveGlobalWrite` appends the same `Date` it checked with.
- A reservation of `w1:p1` makes the next reservation of that pane a per-agent refusal and leaves another pane allowed. A refused reservation does not fill the minute: one allowed, one refused, five more panes, and the next is the global refusal. Eight checks do not fill it. Six `reserveGlobalWrite` calls do, and the seventh is the global refusal. Twenty free-tier reservations do not take the slot. Three answers still refuse a gated check with the consecutive-answer reason, and a confirm-tier reservation of that same pane is allowed.
- A session reservation cools the other pane and is one global write: five more reservations fit, and the next global reservation does not. `noteAgentCooldown` on a session cools that pane and the other pane that names the session, and still leaves room for six global reservations. A cooled pane does not block `reserveGlobalWrite`. Noting the spawned pane's cooldown afterwards does not make that spawn a second global write.
- MCP: no `recordWrite` remains on a send path, so a reservation is not counted twice. Answer and gated say reserve after the write gate and the confirm read, and answer still records the answer only after `sendKeys` returns. Interrupt and stop reserve on `current.paneId` and `current.sessionIdentity` after `revalidate`. Spawn's global reservation is before `createWorkspace` / `createTab` / `splitPane`. `noteAgentCooldown` is after the brief, where `recordWrite` was.
- A send that throws after a successful reservation keeps the slot. A spawn that fails after the reservation keeps the global slot and does not cool a pane that never finished starting. The menu bar does not use this budget; those writes are the person's.
- Not compiled and not run. No Swift toolchain on this box.

### Pass 20 — a second retarget of a moved pane does not drop its detection hash

A poll can continue several sessions at once. `applyHerd` awaited `HeartbeatPoller.retarget` once per move. The first replace is queued before that await yields, so it runs before `pane.moved`. A later move is not queued yet. The event loop can `retargetVacant` it in that gap, and the heartbeat can prune the old id, because the store has already dropped it. The poll's replace then finds the origin empty. An empty origin is also what a mover that has never been polled looks like, and that replace clears the destination so the next poll is not compared against a previous occupant's screen. After the hop, the destination's hash is the mover's. Clearing it makes the next poll a first look, and the screen the pane landed on never counts as output. One move in the snapshot did not take this path: its replace was already queued.

`retarget` remembers an origin whose screen it carried. A vacant retarget does too, including when the new id already had a hash and the origin's copy is dropped. A later replace of that same hop does nothing. It does not clear the destination, and it does not install a hash a read of the old id stored after the move. That read is still a first look on the old id. An origin that was never polled records nothing, so its replace still clears. The record stays through prune while the new id is in the herd. Prune is what runs in the gap, and dropping the record there would let the replace clear the screen. The poll replaces every move in one call, so neither the event loop nor prune can run between the panes of that snapshot. A hop the event already carried returns no second time, and the caller does not write the clock again.

Why this one: backlog item 25. Items 1–24 and 26 stay deferred. This is the detection hash the silence clock is compared against, dropped when one poll continues more than one session.

Files:
- `Sources/HerdrManagerCore/Diagnosis/HeartbeatPoller.swift`
- `Sources/ShepherdApp/AppModel.swift`
- `Tests/HerdrManagerCoreTests/DiagnosisTests.swift`

Self-review:
- Swift 6: `relocatedTo` is actor state on `HeartbeatPoller`, next to the hash map. `AgentID` is `Hashable` and `Sendable`. `retarget(replacing:)` is a synchronous method on that actor and calls `retarget(from:to:)` without leaving it, so a prune queued behind the call cannot run between panes. The dictionary it returns is `[AgentID: Date]`, both `Sendable`. `AppModel` is `@MainActor` and awaits the one call. No new macOS API, import, or protocol requirement. `retarget(from:to:)` is unchanged for a hop that has not been carried, including the clear of a never-polled origin.
- Vacant, then replace: a baseline of "one" stays on the new id, so "two" is a change. The same order when the new id was already hashed "alpha" keeps that hash, and "beta" is a change. A compared change returned by the vacant call is still there for the hop after the replace, which returns nil. A never-polled origin, vacant then replace, still clears, so the next screen is a first look.
- A second replace of a hop that already moved leaves a first look that landed afterwards on the old id. The new id still holds "one", so "shell" is a change. The same second replace leaves the parked change in place, and the following hop returns it.
- Prune that keeps only the new id, between the vacant call and the replace, does not drop the record. "two" is still a change, and the old id has no date. Prune of an empty herd still drops a change that never moved, and the following replace still returns nil.
- One `retarget(replacing:)` of two polled panes and one never-polled origin moves both screens and clears the third. The two landed screens are changes. The cleared destination's next screen is a first look. The call returns no date for a baseline.
- The menu bar copies `sessionMoves` before the await and passes the whole map. Selection and a silence already announced still follow in the synchronous loop. A snapshot the store rejects still returns before any retarget. The event loop's own replace and vacant calls are unchanged; a hop the poll already carried does not clear what they stored.
- Not compiled and not run. No Swift toolchain on this box.

### Pass 21 — MCP diagnosis keeps the episode it already saw

`herd.overview`, `agent.list`, `agent.inspect`, and `agent.diagnose` built a fresh `Agent` on every call and stamped `enteredAt` at that call. herdr puts no clock on the pane. A block the server had been asked about for ten minutes still diagnosed as waiting for 0s, and a working agent could never go quiet: silence is measured from the later of the last output and the episode start, and both were "now". The menu bar does not have this hole. It stamps the episode when the status changes and hashes the detection screen on a 10s heartbeat.

The MCP process now remembers the first observation of a status and `state_change_seq`. A later call reports that clock. A cross-workspace move keeps it when exactly one pane left and exactly one new pane carries that session, at the same status and seq, and the detection hash moves with the pane so the next read is not a first look. An empty session value does not link two panes. A session value that continues with `|` (`abc` versus `abc|extra`) does not either. Learning the session, or a read that omits it, does not open a new episode. A status change, a seq change, a different session, or a restarted lower seq does.

Working panes are read from the detection screen, at most once every 10s, the same cadence as the menu bar. An unchanged screen ages the silence clock. A screen that changed does not. A read that never succeeded is treated as output just now, so a busy agent whose screen could not be read is not called quiet. herdmgr is unchanged: its dwell already comes from the event stream, and it still does not classify silence.

Why this one: backlog items 1–26 stay deferred (below). Item 17 is the menu-bar clock herdmgr does not have. These four tools already run the diagnoser, and the clock they handed it was the call itself. The answer was a duration that had not happened.

Files:
- `Sources/HerdrManagerCore/Diagnosis/DiagnosisEpisodeLedger.swift`
- `Sources/herdr-manager-mcp/HerdrManagerMCP.swift`
- `Tests/HerdrManagerCoreTests/DiagnosisEpisodeLedgerTests.swift`

Self-review:
- Swift 6: the ledger is a `Sendable` value type. It lives on the MCP server actor and is mutated before any `await`. `HeartbeatPoller` was already an actor; the server holds one and awaits `retarget(replacing:)` before `poll`, so a move's hash is in place for that call's read. `Observation` has an explicit public init. No new macOS API. The output dates are collected, then written: the loop awaits a baseline per pane, and assigning into `agents` while iterating it is a trap. `outputDate` is a pure function. A non-working status returns nil and leaves `lastOutputAt` unset.
- Same episode: a second read keeps the first `enteredAt`. A status change, a seq change, and a different session each start a clock. The first read that names a session, and a later read that omits it, keep the clock, and the following move of that session keeps it too. One dropped pane and one new pane with that session keep the clock and name the move; the other pane's clock stays. A seq of 9 then 1 on the new id starts a clock and does not retarget. Two panes sharing a session, an empty session value, and `abc` versus `abc|extra` do not continue. A pane that leaves is forgotten, including when the only other row is a shell, so the same id coming back starts a clock.
- A working pane with a baseline uses it. A working pane with none uses now. Blocked and idle do not get an output date.
- The server copies those clocks onto the agents before `diagnose`. Overview, list, inspect, and diagnose all go through that copy, so a single-agent call still advances the herd's clocks. A move returned by the ledger is the set `retarget(replacing:)` already applies in one turn. The 10s stamp is recorded before the poll, so a second call in that window does not read the screen again; the stored baseline is what the silence clock uses.
- A quiet verdict still needs two detection reads at least the silence threshold apart. The first call in a process is 0s. A gap long enough for the detection buffer to scroll can match an older hash (item 27). herdmgr still does not classify silence (item 17).
- Not compiled and not run. No Swift toolchain on this box.

## Backlog / ideas

Pass 21 re-checked items 1–27. Item 25 is done. Item 17 still applies to herdmgr; MCP's diagnosing tools now keep the episode clock (pass 21). The rest stay deferred for the reasons already recorded. Item 20's send still refuses because explain was addressed to the old pane; the cap follows the session. Item 26 is unchanged: the prefix check is still only applied to fingerprints stored on that same budget key. Item 27 is the limit of the MCP clock.

1. A seq-less `pane_updated` that arrives after a poll already applied a newer status still flips the pane. The event carries no seq, so it cannot be told apart from a genuine second prompt. Deferred again: any rule that drops a seq-less status change also drops the live update the subscription exists to deliver. A non-zero seq is already ignored when it is behind the stored one.
2. Dwell restore still matches a reused pane on kind + non-zero seq + status. `agent_session.value` is parsed onto `HerdrAgentInfo` and not kept on `Agent`. Putting it in the occupant fingerprint would also change Settings override keys (`DwellTracker.fingerprint` and `AppModel.fingerprintForAgent` must stay identical). Deferred: needs a second identity stored on `Agent` and in the dwell file, with old files still matching, and it is a separate change from the answer-send check. Pass 17 follows a session when an approved pane id is gone. The dwell file still does not, and `Agent` still has no session field.
3. `paneBasis` keeps a tombstone for a pane a status, presence, or move event touched, including the previous id after a cross-workspace move, so a late pre-event list cannot resurrect it. Pane ids are not reused; the map grows with ids seen this launch. Deferred: one or two structs per moved pane per launch is not worth a pruning rule that might drop a basis an in-flight read still needs.
4. A herdr restart that reuses a pane id and comes back at the same `state_change_seq` with the same occupant fingerprint does not reset the 3-answer cap. Deferred: that read looks exactly like a second observation of the episode the cap is counting. Resetting on an equal seq would let a stale read clear the cap, which the policy test forbids. A lower seq, or the same seq with a new occupant fingerprint on the same budget key, does reset. A different session identity is its own budget (pass 18).
5. Done in pass 7. A connect failure, a refresh that fails, and a dropped subscription clear the protocol under the enqueue epoch. A herd read that already started cannot record over that clear. A read that starts afterwards still can. `setLatestProtocol` with a nil epoch still bypasses that floor; no request path calls it that way.
6. Gated `agent.say` reads the pane, then awaits `checkWritesEnabled`, then prompts, with no second read. A status change in that gap still receives the text. Deferred: it is a message, not a key bound to one prompt, and the confirm-tier tools already revalidate immediately before their send. That revalidation follows a unique session when the pane id itself moved (pass 17). The gated path still does not. Pass 19 reserves the write budget after that await, so a write that landed in the gap is refused; the text still goes to the id from the first read.
7. `HerdrAgentInfo.==` does not compare `agentSession` (`AgentSession` is not `Equatable`). `AnswerSendCheck` uses the fingerprint, not `==`. The store, the snapshot merge, and the write path do not branch on `HerdrAgentInfo` equality, so the missing field does not change behavior today. Deferred: making `AgentSession` equatable is safe, and still has no caller.
8. Done in pass 8. herdmgr's layout refetch no longer leaves a moved pane on a fresh dwell. The move copies the pre-refetch `enteredAt` onto the new id when status and seq still match, including when several panes move in one burst. A refetch after one of those moves has been applied starts a new baseline; a later move whose previous id is only on the old baseline keeps the reset dwell. A status or seq change is not restored. Shepherd still does not refetch on those events.
9. A seq-less `pane_moved` does not adopt a status that appears only on that payload. Deferred: `PaneInfo` has no seq, so a live status and a replayed one are the same bytes. Applying the payload status is what made a protocol-17 buffer replay reopen a blocked episode. `pane.updated` and Shepherd's poll still carry status. herdmgr misses a status change that arrived only inside the move until the next `pane_updated`.
10. A seq-less `pane_moved` with no agent still drops a row whose id matches. A replayed same-id move-to-shell can remove an agent that started in that pane later. Deferred: a live move to a shell has the same shape, and leaving the row would stick in herdmgr. Shepherd's next poll inserts the agent again.
11. A mutation already queued ahead of the snapshot that records a downgrade still runs. Deferred: the I/O queue is serial, and that write started when the gate was still open. Waiting for a read that has not been enqueued would stall every keystroke on a snapshot nobody requested. Pass 9 refuses the write once the downgrade's transaction is ahead of it.
12. Done in pass 11. The last usage event stays out of the history fold, with the unterminated tail. A Claude message that is still the last usage line keeps its id when a week or month boundary folds the older lines, and the next copy replaces it. The older lines in that session still fold.
13. A repeated Claude usage line that is no longer the last usage event can still be folded and then counted twice. An edit of bytes behind the resume signature is still unseen. Deferred: both sit behind a newer line, or behind bytes the append reader does not visit. Keeping every id that has ever been last would stop the older history from folding.
14. Done in pass 12. A silence measured at the start of a diagnosis pass is measured again on the row as it is when the verdict lands. Output inside the threshold leaves the pane healthy, including a quiet it was already showing. The heartbeat's newer output time clears that quiet immediately. A time that is still before the episode does not. Process-gone is unchanged.
15. A diagnosis result for a pane that moved while the pass was in flight is dropped. The old id is gone, and the new id keeps the verdict from before the pass until the next one. Deferred again: pass 15 records the id change, but the read was issued against the old pane id. After the move that id can be a bare shell, and stamping process-gone onto the new id would mark a live agent gone. The next pass reads the new id.
16. Done in pass 13. A crashed pane is its own bucket, mark (`GONE`), and footer count. herdmgr reads the process list before paint, after events, and every 15s, so a dead process is not shown as working or blocked. A failed read does not clear a crash. MCP uses the same mark and does not count a crash as unknown as well.
17. herdmgr does not classify silence. Deferred: the table has no output clock. Timing silence from `enteredAt` would mark a busy agent quiet at the 5-minute threshold. The menu bar's heartbeat is what makes that clock real. MCP's diagnosing tools keep an episode clock and a detection baseline across calls in that process (pass 21). herdmgr's live table still does not.
18. A poll that lands before `pane.moved` still starts a new episode when the pane has no `agent_session.value`. Pass 15 carries the episode only when exactly one dropped pane and one new pane share a non-empty session value. Deferred: kind and title are shared by agents that are not the same occupant, and an empty value is what several panes look like. Selection and the detection hash still follow when the event arrives, because the new id is already a row. The duplicate blocked alert and the reset dwell for that session-less pane do not.
19. A detection read that finishes after the hash was already moved still records on the old id and does not carry a change. The next poll of the new id reports a screen that differs from the hash the move saved. Deferred: the read was addressed to the old pane id, and after the move those bytes can be the shell that replaced the agent. Parking them would clear a silence for output the agent did not produce. Pass 16 carries only a change the poll had already compared against the mover's own previous screen. A later replace of that same hop no longer installs the first look on the destination (pass 20). The read itself is unchanged.
20. `agent.answer` still refuses when its pane id is gone, including when the same session is blocked on the same seq at a new id. `explain` was addressed to the old pane. After the move that id can be a shell, and the block kind that justified the keys is not a reading of the new pane. Deferred: the explain gap is short. The consecutive-answer cap follows the session (pass 18), so addressing the new id spends the same budget. Confirm-tier writes follow the session; they do not explain a screen. The refusal stays locked by `AnswerSendCheck`'s gone-pane test.
21. Close, Nudge, Jump, and gated `agent.say` still address the pane id from the click or the first read. Deferred: they do not hold that id across the confirmation wait. A move during the one socket call is the write that was already queued. Close needs its own rule for whether a status change still means that occupant. Gated `agent.say` does record its cooldown on the session (pass 18), so a later write to the moved id waits out the 10s; the text itself still goes to the id from the first read.
22. The moved row's Approve button stays enabled while the original click is in flight. The click is ignored, and the footer says a response is already being sent. Deferred: disabling the button means the in-flight id set has to follow every later hop and be removed only by the task that started it. The session set already stops the second Enter.
23. A pane with no `agent_session.value` still gets a fresh answer cap and write cooldown when its id changes. Deferred: an empty value is what several panes look like, and kind plus title are not an occupant. Pass 18 follows only a non-empty session identity. The pane that was actually written stays in cooldown for 10s either way.
24. Answers recorded before a session value existed stay on the pane id. The first `recordStatusChange` that carries a session starts that session's budget at zero and clears the pane mirror on the id it observed. Deferred: treating that as the same occupant would also adopt a previous occupant's count when a new session reuses the pane at the same seq, which is the reset pass 4 exists to do. A session that is present for the whole episode is the path pass 18 covers.
25. Done in pass 20. A poll that continues several sessions replaces every detection hash in one call. A second replace of a hop that already moved does not clear the destination, and does not install a hash the old id recorded after the move. A never-polled origin still clears. Prune keeps that record while the new id is in the herd. A single move was already safe; this is the later pane in the same snapshot.
26. `fingerprintBelongs` treats a session value that continues with `|` (`abc` versus `abc|extra`) as the same occupant. `abc` versus `abcd` does not, and that case is tested. Deferred: the budget key is the identity string itself, and MCP passes the fingerprint and the identity from the same `HerdrAgentInfo`, so the two values are different keys. The prefix check only runs for fingerprints stored on that same key. The diagnosis episode clock compares the identity strings exactly, so this prefix does not join two clocks (pass 21).
27. MCP blocked and quiet durations start when that process first sees the episode. herdr has no wall clock to backdate them. A call that never got a detection read does not start the silence clock. Quiet begins only after a later read still sees that same screen, past the threshold. A gap long enough for the detection buffer to scroll can match an older hash and report quiet. Deferred: writing the clock into Shepherd's dwell file would share that file with no cross-process lock. The first call in a process reporting 0s is the observation, not a claim about the time before the server started.

## Notes

Branch `grok/ehf-loop-0926`, from `origin/main` at `34c211e`. This file was empty at the start of pass 1.
