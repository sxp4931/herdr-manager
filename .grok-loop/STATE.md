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

## Backlog / ideas

Pass 15 re-checked items 1–17. They stay as written. None of them is the poll that lands the new pane id before `pane.moved`. Item 18 is the part of that race this pass did not close.

1. A seq-less `pane_updated` that arrives after a poll already applied a newer status still flips the pane. The event carries no seq, so it cannot be told apart from a genuine second prompt. Deferred again: any rule that drops a seq-less status change also drops the live update the subscription exists to deliver. A non-zero seq is already ignored when it is behind the stored one.
2. Dwell restore still matches a reused pane on kind + non-zero seq + status. `agent_session.value` is parsed onto `HerdrAgentInfo` and not kept on `Agent`. Putting it in the occupant fingerprint would also change Settings override keys (`DwellTracker.fingerprint` and `AppModel.fingerprintForAgent` must stay identical). Deferred: needs a second identity stored on `Agent` and in the dwell file, with old files still matching, and it is a separate change from the answer-send check. The MCP write path compares session value; the panel Approve/Deny check and the dwell file still do not.
3. `paneBasis` keeps a tombstone for a pane a status, presence, or move event touched, including the previous id after a cross-workspace move, so a late pre-event list cannot resurrect it. Pane ids are not reused; the map grows with ids seen this launch. Deferred: one or two structs per moved pane per launch is not worth a pruning rule that might drop a basis an in-flight read still needs.
4. A herdr restart that reuses a pane id and comes back at the same `state_change_seq` with the same occupant fingerprint does not reset the 3-answer cap. Deferred: that read looks exactly like a second observation of the episode the cap is counting. Resetting on an equal seq would let a stale read clear the cap, which the policy test forbids. A lower seq, or the same seq with a new session value, does reset.
5. Done in pass 7. A connect failure, a refresh that fails, and a dropped subscription clear the protocol under the enqueue epoch. A herd read that already started cannot record over that clear. A read that starts afterwards still can. `setLatestProtocol` with a nil epoch still bypasses that floor; no request path calls it that way.
6. Gated `agent.say` reads the pane, then awaits `checkWritesEnabled`, then prompts, with no second read. A status change in that gap still receives the text. Deferred: it is a message, not a key bound to one prompt, and the confirm-tier tools already revalidate immediately before their send.
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
17. herdmgr does not classify silence. Deferred: the table has no output clock. Timing silence from `enteredAt` would mark a busy agent quiet at the 5-minute threshold. The menu bar's heartbeat is what makes that clock real.
18. A poll that lands before `pane.moved` still starts a new episode when the pane has no `agent_session.value`. Pass 15 carries the episode only when exactly one dropped pane and one new pane share a non-empty session value. Deferred: kind and title are shared by agents that are not the same occupant, and an empty value is what several panes look like. Selection and the detection hash still follow when the event arrives, because the new id is already a row. The duplicate blocked alert and the reset dwell for that session-less pane do not.

## Notes

Branch `grok/ehf-loop-0926`, from `origin/main` at `34c211e`. This file was empty at the start of pass 1.
