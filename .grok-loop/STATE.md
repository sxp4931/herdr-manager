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

### Pass 22 — a gated say re-reads the occupant before it submits Enter

MCP `agent.say` auto-sends when the agent is idle or done. `prompt` writes the text and then Enter. The pane id came from the read that chose the tier, and the policy check after that read awaits. A cross-workspace move in the gap left the agent on a new id, and the Enter went to the pane they had left. A block that appeared in the same gap received the Enter without the confirmation a working or blocked say waits for. The earlier deferral treated the payload as text. The send is text and Enter.

The gated path lists the herd again after that await and addresses `GatedSayFollow`. The original pane wins when it still runs the same occupant. A different occupant refuses, including when the old session is also on another pane, and does not take a write slot. A pane that is no longer an agent follows a unique session, and only while that pane is still idle or done. Working or blocked refuses, so a retry takes the confirm tier. An empty session value does not follow a pane that left. A session value that continues with `|` (`abc` versus `abc|extra`) does not either. Idle and done still receive the text when the seq changes: nothing is waiting, and the Enter is the message's own submit. The tier and the re-read share `acceptsAutoSend`. The confirming list records the protocol, and the gate is read from it before the slot is taken. The reserve, the journal, and `wait_for` use the pane that list named.

Why this one: backlog item 6. Items 1–5 and 7–27 stay deferred. Confirm-tier say, interrupt, and stop already revalidate after the approval wait. This is the auto path, which did not.

Files:
- `Sources/HerdrManagerCore/Policy/ConfirmedPaneFollow.swift`
- `Sources/herdr-manager-mcp/HerdrManagerMCP.swift`
- `Tests/HerdrManagerCoreTests/PromptAnswerCheckTests.swift`

Self-review:
- Swift 6: `GatedSayFollow` is a `Sendable` enum of pure functions. It calls `ConfirmedPaneFollow.uniqueSuccessor`, which is internal to the same module. No new actor, isolation, macOS API, or signature an existing caller must adopt. `acceptsAutoSend` compares `AgentStatus.idle` and `.done` raw values, which are the strings the tier used. The MCP server is an actor. The confirming `readHerd` is the next herd call after `checkWriteAllowed`. `adapter.health()` is the synchronous locked read `throwIfWritesDisabled` already uses. A refusal returns before `reserveWrite`.
- Same occupant, still idle, including a new seq and a renamed title: the write stays on that pane. Done to idle stays too. Idle to working, and idle to blocked, refuse on that pane. A different session in the pane refuses even when the old session is idle on another pane. A re-read that drops `agent_session` refuses: the fingerprint changed, and the text does not go out on a guess.
- One idle successor, including a seq bump, a renamed title, and a session value that contains `|`: the write uses the new pane id. Done follows the same way. A blocked or working successor refuses, and the refusal names the new pane. A shell left at the old id does not hide the idle successor. Two successors, a missing pane, a fallback fingerprint, an empty session value, `abc` versus `abc|extra`, and an empty pane id do not follow. A title change with no session refuses on the same pane.
- The slot is taken only after that resolve and the gate check, on the pane and session that will be addressed. A refusal does not record. `wait_for` polls the same pane. The tool result names `resolvedAgentId` when the id changed. Confirm-tier say is unchanged: it still requires the approved status and seq.
- A move during `reserveWrite`, after the confirming list, still addresses that list's id. The prompt is then the write already queued. The pre-check still names the caller's pane id, so a cooldown stored on that id with no session still refuses before the follow. A say that had the session cools the session, which is the refusal that should stick.
- Not compiled and not run. No Swift toolchain on this box.

### Pass 23 — Approve refuses a different session that reused the pane

The panel copies `agent_session` before the re-read and passes it to `PromptAnswerCheck`. That identity was used only when the pane id had left the list. While the id was still an agent, the check compared kind, status, and seq. Kind is the agent name. A new session of the same kind, still blocked, on the same `state_change_seq`, compared equal, and Enter or Esc went to a prompt the click did not show. A herdr restart that mints a new session value and comes back blocked on that same seq has this shape. MCP already refuses it: `AnswerSendCheck` and `ConfirmedPaneFollow` compare the occupant, not the kind.

When the click captured a session, the pane still has to name that session. A different value refuses, including one that only continues with `|` (`abc` versus `abc|extra`). A re-read that drops `agent_session` refuses too: the field is the occupant, and the keys do not go out on a guess. The old session sitting on another pane is not addressed while this pane still runs an agent. The same session still sends, including after a title change. A status or seq change on that session is still "no longer waiting" or "prompt changed", not "a different agent". A move that drops the pane still follows the one successor. Callers that captured no identity keep the kind comparison. There is no session to require, and kind plus title are not an occupant.

Why this one: backlog items 1–27 stay deferred (below). This is the menu bar's Approve and Deny, which already re-read, still accepting a prompt the row did not show. The identity was already on the call.

Files:
- `Sources/HerdrManagerCore/Policy/PromptAnswerCheck.swift`
- `Tests/HerdrManagerCoreTests/PromptAnswerCheckTests.swift`

Self-review:
- Swift 6: the compare is inside `PromptAnswerCheck`, a `Sendable` enum of pure functions. `sessionIdentity` was already a parameter, defaulted to nil. No new type, isolation, macOS API, import, or signature. `if let sessionIdentity` unwraps that optional. The guard binds `String` to `String`. `AppModel.sendKeys` already copies `store.sessionIdentity(for:)` before the task and passes it to `destination`. No call site change.
- A different session at the same kind, blocked status, and seq refuses, and does not follow the old session onto another pane. `abc|extra` refuses against `abc`. A re-read with no `agent_session` refuses. The same session, including a value that itself contains `|`, still addresses that pane after a title change. That session going working is `notBlocked`. A higher seq is `promptChanged`.
- Omitting the identity still addresses the pane on kind and seq. That is the click that had no session to copy. A move of the captured session still addresses the new pane: the same-pane branch does not run once the id is gone. A shell left at the old id still follows. Two successors still refuse. The original pane still wins when it is the same session.
- A restart that comes back with the same session value and the same seq still sends. That read looks like a second look at the episode, which is item 4.
- Not compiled and not run. No Swift toolchain on this box.

### Pass 24 — a slower MCP herd read cannot rewind the diagnosis clock

`herd.overview`, `agent.list`, `agent.inspect`, and `agent.diagnose` run at the same time as each other. Pass 21 keeps the episode on the ledger inside the MCP process. Each call observed whichever snapshot it held when it resumed, so the slower read — the earlier herd — applied last. A block the server had already been timing was stamped back to "just now", a pane the later read had added was forgotten, and the losing call's prune deleted the detection hash the later read had just stored. The next screen on that pane was a first look, so output the agent had already produced did not move the silence clock.

The herd-read serial is captured before the request, which is also the order the adapter enqueues the snapshots. `observeIfCurrent` adopts only a strictly newer serial. An older one, an equal one, and a missing zero leave the ledger alone. The losing call reports a clock the ledger still has for that same status and seq, and it does not poll or prune. After the winning call notes its serial on the poller, a poll that is still inside `pane.read` drops the bytes instead of storing them, and a poll that has not started does not read. The 10s cadence is stamped only once that poll is still the latest serial when it returns, so a dropped read does not make the newer herd skip the screen. Shepherd's heartbeat does not pass a serial and still records.

Why this one: backlog items 1–28 stay deferred (below). This is the episode clock pass 21 added, still applied in completion order. The menu bar's store already drops an older herd serial. The MCP process is where those reads overlap.

Files:
- `Sources/HerdrManagerCore/Diagnosis/DiagnosisEpisodeLedger.swift`
- `Sources/HerdrManagerCore/Diagnosis/HeartbeatPoller.swift`
- `Sources/herdr-manager-mcp/HerdrManagerMCP.swift`
- `Tests/HerdrManagerCoreTests/DiagnosisEpisodeLedgerTests.swift`
- `Tests/HerdrManagerCoreTests/DiagnosisTests.swift`

Self-review:
- Swift 6: the serial is a `UInt64` on the `Sendable` ledger and on the poller actor. `observeIfCurrent` does not await. The poller's new parameter defaults to nil, and `retarget(replacing:)`'s does too, so Shepherd's heartbeat and the existing tests keep their calls. `noteHerdSerial` is a synchronous actor method. No new macOS API. The cadence stamp is a `Date` written on the MCP actor after the poll await, and only while that serial is still latest. `stampDetectionOutput` returns a new dictionary instead of holding `inout` across the baseline reads.
- Ledger: serial 0 does not adopt and is not latest. Serial 2 keeps the blocked clock. Serial 1, carrying a different status, does not replace it, and that status does not borrow the clock. Serial 4 moves the episode and serial 2 stops being latest. The same serial 4, with a status that would otherwise reset the clock, leaves the moved episode in place. The old pane id no longer has the clock.
- Poller: a serial-1 read whose screen arrives after serial 4 was noted does not replace the baseline, and the following serial-4 read of that same screen is not a change. A serial that is already behind does not fetch. An untagged poll still records, and serial 0 does not. A retarget that notes serial 5 leaves the old id without the shell the older poll wanted to store, so the next screen there is a first look, and the new id still compares against the screen that moved.
- MCP: the four diagnosing tools pass the serial from the capture immediately before `herdSnapshot`. A losing serial does not observe, retarget, poll, or prune. The winning call notes the serial on the retarget when a session moved, and on its own when nothing moved, before it polls. `readHerd` still captures one serial for every other tool.
- A poll that stored its screen and then lost the race has already recorded that screen. The newer read retargets or polls from there. A poll that loses during the read records nothing. Item 19 still covers a detection read Shepherd addressed to a pane id that has already moved.
- Not compiled and not run. No Swift toolchain on this box.

### Pass 25 — a new session in the same pane does not keep the old episode

Approve already refuses when the pane is still blocked on the same seq but the session value changed. The row did not. `applyHerdSnapshot` treats the same status and the same seq as the same episode, so the new occupant kept the previous dwell, the silence or crash verdict, and `lastOutputAt`. No transition fired, so the menu bar did not alert and did not diagnose. A `pane_updated` or a move that names the new session did the same. herdmgr's layout refetch preserved that dwell, and the following `pane.moved` put it back onto the new id. A diagnosis pass that had already read the old pane then stamped process-gone onto whoever was there now, because the guard only compared status and seq.

A replacement is both sides naming a session and those strings differing, including `abc` versus `abc|extra`. A missing value is not one: the field arrives late, and a seq-less event leaves it off. The first list that names a session keeps the episode. The store opens a new dwell, drops the old verdict, and reports a transition even when the status string did not move, so a block alerts again under the new `enteredAt`. The event tombstones the pane. A list captured before it cannot paint the old session back over the one the event stored; remembering that list's occupant made the next read look like another replacement. herdmgr resets on the refetch and on `pane_updated`, and does not restore that dwell when the move arrives. A verdict measured for the session the pass started with is not applied after a different one has taken the pane. Learning the session during the read still applies.

Why this one: backlog items 1–28 stay deferred (below). Item 2 is the dwell file and the settings key, which still match on kind. This is the live row those checks already treat as a different person. MCP's episode ledger already reset this clock.

Files:
- `Sources/HerdrManagerCore/Domain/Types.swift`
- `Sources/HerdrManagerCore/Store/AgentStore.swift`
- `Sources/HerdrManagerCore/Domain/HerdSnapshot+Dwell.swift`
- `Sources/HerdrManagerCore/Diagnosis/DiagnosisEpisodeLedger.swift`
- `Tests/HerdrManagerCoreTests/AgentStoreHerdTests.swift`
- `Tests/HerdrManagerCoreTests/HerdSnapshotDwellTests.swift`

Self-review:
- Swift 6: `SessionIdentity.replaced` is a static function on an enum with no stored state. The new fields stay on the `@MainActor` store and on `HerdLiveTable`, which is a `Sendable` value the CLI mutates on the task that owns the event loop. `diagnoseAll` copies the session strings before its first await. New parameters default, so a caller that does not track sessions still preserves dwell, and `transition` without the flag still ignores an unchanged status. No new macOS API, import, or isolation.
- Same pane, same blocked seq, session `abc` then `other`: one transition from blocked to blocked, the silence is gone, `enteredAt` moved, and the stored identity is `other`. `abc|extra` does the same against `abc`. The first time a session appears, and a later list that omits it, keep the pinned dwell. A seq-less `pane_updated` that omits the session keeps the dwell and the identity. One that names `other` opens the episode, and the list captured before that event does not put `abc` or the old dwell back.
- A move payload that names `other` re-keys, does not keep the silence, and leaves the old id with no identity. A move that omits the session still carries the one the list stored; that path is the existing same-session tests.
- herdmgr: a refetch from `abc` to `other` drops the crash and the old dwell, the other pane keeps its dwell, and the move does not put the old dwell on the new id. The first session value keeps the crash. A second `pane_updated` of the session just stored does not open another dwell.
- Diagnosis: a bare-shell read started for `abc` does not stamp process-gone after `other` has taken the pane at the same seq. A read that learns the session while it is in flight still stamps the silence it measured.
- The ledger's occupant compare now calls `SessionIdentity.replaced`. Nil and equal strings still keep the clock; two different strings still do not.
- Not compiled and not run. No Swift toolchain on this box.

### Pass 26 — a list that omits the session does not forget the occupant

Pass 25 opens a new episode when the pane already has a session and the next read names a different one. A missing value is not that change, so the first list that names a session keeps the dwell, and a later list that leaves `agent_session` off was supposed to keep the identity too. `rememberSessions` did the opposite for any pane the list actually contained: no session on that entry deleted the one already stored. The row's dwell did not move, which is why the episode looked intact. The next list that named a person was then the first session this pane had ever had, and the silence, the crash, and the dwell stayed with them. herdmgr's layout refetch rebuilt the same map from the snapshot alone, so a refetch that omitted the field cleared it before the following `pane_updated`.

A kept pane with no session on this list keeps the identity it had. A list that names one still replaces it. A pane this snapshot was not allowed to paint over still keeps the identity the event stored, including when the stale list names the previous occupant. A pane that left the herd is not kept, and its identity goes with it. herdmgr does the same for a row that is still on screen, and a burst still remembers the id that already moved so the following `pane.moved` can tell the two sessions apart. MCP's ledger already left a stored session in place when a read omitted the field.

Why this one: backlog items 1–28 stay deferred (below). Item 2 is still the dwell file. This is the live occupant pass 25 records, dropped by the next poll that did not repeat it, which is the poll the menu bar runs every 3 seconds and the refetch herdmgr runs on a layout event.

Files:
- `Sources/HerdrManagerCore/Store/AgentStore.swift`
- `Sources/HerdrManagerCore/Domain/HerdSnapshot+Dwell.swift`
- `Tests/HerdrManagerCoreTests/AgentStoreHerdTests.swift`
- `Tests/HerdrManagerCoreTests/HerdSnapshotDwellTests.swift`

Self-review:
- Swift 6: no new type, isolation, or macOS API. The map stays `@ObservationIgnored` on the `@MainActor` store, and on `HerdLiveTable`, which is a `Sendable` value herdmgr mutates on the task that owns the event loop. `rememberSessions` still runs after the episode decision and does not await. The holding branch is still the one that ignores an incoming session.
- A list that names `abc` for the first time keeps the pinned silence. The next list, same status and seq, with no session, keeps that silence and still reports `abc`. The list after that, naming `other` at the same seq, is one blocked-to-blocked transition, drops the silence, and stores `other`. `abc|extra` is already a different occupant once the stored string is still there.
- A pre-event list that names the old session still does not replace the session the event stored. That branch did not change: holding wins before the incoming value is read.
- herdmgr: a refetch that drops the field keeps the crash and the dwell, and the other pane's dwell. The following `pane_updated` that names `other` opens one dwell and clears the crash. A refetch that names `other` itself still opens the dwell, because the snapshot's session is written before the fill. A burst still copies the pre-move id's session when the new snapshot no longer lists that id.
- A pane that becomes a shell is not in the kept rows, so the old session is not stuck on it. An empty session value is still not an identity, and a list of those does not count as a replacement either.
- Not compiled and not run. No Swift toolchain on this box.

### Pass 27 — herdmgr's live table takes the title, kind, directory, and tab from pane_updated

`pane_updated` is the event herdr sends when the stripped terminal title changes, and the wire pane carries the detected agent, cwd, and container ids. herdmgr's table has no poll. `HerdSnapshot.applying` copied status onto an existing row and left the name, kind, directory, and workspace/tab from the last snapshot, so the NAME and KIND columns stayed on whatever the process first drew until a layout refetch. Shepherd already copies those fields in `AgentStore.applyEvent`. The menu bar's 3s poll covers a title the event left off. The CLI does not.

A same-status update now refreshes them and still keeps the dwell and a crash. `title` wins over `terminal_title_stripped`. An empty string is absent, so a seq-less payload that leaves the title off does not replace it with the agent kind. Kind prefers a non-empty session agent, then the detected `agent`. Directory prefers `foreground_cwd`. Workspace and tab change only when this snapshot already has a label for the id: a raw id must not replace the name a move just created, and the layout refetch is what teaches the snapshot a new container. A seq behind the stored one is still ignored whole, title included. A real status change still opens an episode and takes the new title. A title change does not drop the pre-move dwell a layout burst is holding.

Why this one: backlog items 1–28 stay deferred (below). This is the live table's name, which is the column that says which agent needs you, stuck on the snapshot that opened the process.

Files:
- `Sources/HerdrManagerCore/Domain/HerdSnapshot+Events.swift`
- `Tests/HerdrManagerCoreTests/HerdSnapshotEventsTests.swift`
- `Tests/HerdrManagerCoreTests/HerdSnapshotDwellTests.swift`

Self-review:
- Swift 6: the new helpers are methods on `HerdSnapshot`, a `Sendable` value type. `applyPresentation` writes an `inout Agent` in the local array `applying` already mutates. No actor, no new isolation, no macOS API, no signature an existing caller must adopt. `HerdLiveTable.apply` still goes through `applying`, so the CLI picks this up without a second copy of the rules.
- Same status, seq 0, session agent `codex`, stripped title "Action Required", foreground directory, tab the snapshot names "tests": the name, kind, cwd, and tab move, and the crash, seq, and `enteredAt` stay. A later event whose `title` is "Metadata" wins over the stripped title and does not open an episode. Empty title, empty directory, and an unknown workspace and tab leave the name, cwd, and "proj" / "scratch" in place, and the detected agent still updates the kind. A seq behind the stored one does not apply its title or its status. A status change to blocked takes "Needs you", starts a dwell, and clears the crash.
- A title change while a layout burst is open shows "Action Required" on the refetched id and keeps that id's reset dwell. The following `pane.moved` puts the pre-refetch dwell back. The move's own payload still supplies the name it carries.
- A pane_updated that omits `agent_session` adopts the detected `agent` string. That is the rule `AgentStore` already uses. The real pane event includes the session; when it does, the session's agent wins. Shepherd's row was already updated by the store. Inserts still go through `displayAgent`.
- Not compiled and not run. No Swift toolchain on this box.

### Pass 28 — a workspace or tab rename keeps its label when the herd read is stale

`workspace.renamed` and `tab.renamed` were already subscribed. The parser folded both into `.workspacesChanged` and dropped the label. Shepherd's store ignores that case, so the row kept the old name until the next `agent.list`. That poll is the request socket. The comment on the refresh loop says that socket can time out while the subscription is still delivering events, and a rename in that window never landed. herdmgr refetched the whole herd for the event, which is how a focus or a created container is learned, and a failed refetch left the old name even though the event had carried the new one. A rename is not a new episode. Refetching it also reset nothing only when the list came back; the label did not need the list.

The two events are their own cases. The store writes the label onto every row in that container and onto the cache a later `pane_updated` reads. A snapshot captured before the rename does not put the old label back, including on a row it is not allowed to rebuild. A snapshot captured afterwards is the herd and clears the pin. A caller that omits the request epoch still applies the label it read. The same label does not bump the epoch, so a poll that had already seen the name is not pinned. An empty label is ignored. herdmgr updates the row and the snapshot map in place, so the next `pane_updated` cannot write the old name back, and a layout burst stays armed. The new-agent menu reads the store's labels, so it shows the same name as the row.

Why this one: backlog items 1–28 stay deferred (below). This is the name next to the agent that needs you, stuck on the previous container until a request that may be the socket that is down. The event already had the label.

Files:
- `Sources/HerdrManagerCore/Domain/Types.swift`
- `Sources/HerdrManagerCore/Adapter/HerdrAdapter.swift`
- `Sources/HerdrManagerCore/Domain/HerdSnapshot+Events.swift`
- `Sources/HerdrManagerCore/Domain/HerdSnapshot+Dwell.swift`
- `Sources/HerdrManagerCore/Store/AgentStore.swift`
- `Sources/ShepherdApp/AppModel.swift`
- `Tests/HerdrManagerCoreTests/AdapterTests.swift`
- `Tests/HerdrManagerCoreTests/HerdSnapshotEventsTests.swift`
- `Tests/HerdrManagerCoreTests/HerdSnapshotDwellTests.swift`
- `Tests/HerdrManagerCoreTests/AgentStoreHerdTests.swift`

Self-review:
- Swift 6: the new event cases are `Sendable` strings on `HerdrEvent`. The stamp and the tab-id map are `@ObservationIgnored` on the `@MainActor` store. `LabelStamp` does not leave that actor. `HerdLiveTable` stays a `Sendable` value; the tab-id map is `[String: String]`. `applying`'s new parameter defaults to `[:]`, and every existing call passes `now:` by label, so the signature does not move. No new macOS API. `renamingWorkspace` returns `self` when the label is unchanged, so a burst is not dropped by a copy that compares equal only by accident. The menu copy compares the option arrays before assigning.
- Both exhaustive switches, the store and `HerdSnapshot.applying`, handle the new cases. herdmgr's `if case .workspacesChanged` still refetches focus, create, and close. A rename is not that case, so it does not await a list, and the burst's `enteredAt` is still there for `pane.moved`.
- Wire: `workspace_renamed` and dotted `tab.renamed` keep id and label. An empty label is `.ignored`, not a refetch. A workspace rename changes both rows in that workspace and not the other one. The crash, the seq, and `enteredAt` stay. The other tab in the same workspace stays. A second event with the same label does not move `currentHerdEpoch`.
- A poll captured before the rename, applied after it, leaves "Renamed" and "suite" on the rows and in the caches. The following `pane_updated` does not restore "Alpha" or "tests". A poll captured after the rename applies the list's "Later". A poll with no request epoch applies the label it read. A status event and a rename, then the poll that started before both, keeps the new status and the new workspace name.
- herdmgr: a rename in the middle of a layout burst leaves the reset dwell, the other pane's name, and the remembered rows. A `pane_updated` after it still says "Renamed" / "suite", because the snapshot map moved with the row. The following `pane.moved` puts the pre-refetch dwell and the crash back and does not put "proj" or the move's created label back over the rename.
- A list captured after the rename whose `agent.list` is still on the old label replaces the pin. That list is the herd the poll started against. herdmgr's later focus refetch is the same: it runs after the rename has been applied, and the list it gets is what the row shows next.
- Not compiled and not run. No Swift toolchain on this box.

### Pass 29 — herdmgr polls the status of the rows it already shows

herdr emits a status change as `pane.agent_status_changed`. That subscription requires a pane id; a global subscribe without one is rejected, which is why it is not in `globalSubscriptionTypes`. `pane.updated` is emitted for a title, a metadata token, or an agent name, not for a status change (`emit_pane_state_update` in herdr 0.7.5). Shepherd learns the new status from its 3s `agent.list`. herdmgr refetched only on a layout event, so a block stayed on the previous status until the user created, closed, or focused a container.

The live table now polls every 3s, the same cadence as the menu bar. The poll updates an id the table already shows: status, seq, and any title, directory, or container label the list actually named. The same status and seq keep the dwell and the crash. A new session, or a new seq, opens a dwell. A list that leaves the title, the directory, or the container label off keeps what the row had. A list that adds a pane, or that drops one, does not change membership. A move's new id is already in `agent.list` before `pane.moved`; adopting that list would replace the row the layout refetch remembers, and the move would put back the reset dwell. `pane.updated` and `pane.closed` still insert and remove. A failed poll changes nothing. An unchanged poll does not redraw. The process scan stays on events and on the 15s tick, so an idle table still notices a dead process, and a poll of the same episode does not paint a status verdict over a crash the scan just stamped.

Why this one: backlog items 1–28 stay deferred (below). Item 9's move payload still does not carry status; once the row is on the id the table shows, this poll applies the list's status without waiting for another layout event. The menu bar already had the poll.

Files:
- `Sources/HerdrManagerCore/Domain/HerdSnapshot+Dwell.swift`
- `Sources/herdmgr/Herdmgr.swift`
- `Tests/HerdrManagerCoreTests/HerdSnapshotDwellTests.swift`

Self-review:
- Swift 6: `noteStatusRefresh` is a mutating method on `HerdLiveTable`, a `Sendable` value type. No actor, no new isolation, no macOS API. herdmgr calls it on the task that already owns the table, after the `await`, the same way `noteLayoutRefresh` is called. `LiveWake` gains `.herd`. The only switch is `watchLiveTable`. `absent` is a private static function on that struct. `displayAgent` is the existing `HerdSnapshot` method.
- A poll that says blocked at seq 5 with title "Needs you" and workspace "Renamed" keeps `enteredAt` and the crash, and does not insert a third pane the list added. The other pane, seq 3 to 9 and working to done, opens a dwell and clears a crash. A following poll that leaves the title, the directory, and both container maps off keeps "Needs you", "/tmp", "Renamed", and "suite".
- A poll whose list contains only the moved id leaves both old rows and their dwell. The layout refetch after that still remembers them, and `pane.moved` puts the original dwell on the new id.
- A poll in the middle of a layout burst updates the title on the new id and leaves the remembered row. The move still restores the pre-refetch dwell and the crash. A nil poll does not.
- An omitted session keeps the dwell and the crash. A different session on that pane opens one dwell and clears the crash. The other pane, same session, stays.
- A rename applied after the poll still wins, and the next `pane_updated` does not write the poll's label back. The poll does not pin a label. The event loop awaits the poll before it reads the next event, so a rename that arrives during the poll is applied after it.
- Not compiled and not run. No Swift toolchain on this box.

### Pass 30 — a renamed agent keeps its name when the terminal title changes

herdr's agents panel labels a row with the metadata `display_agent`, then the name from `herdr agent rename` or `agent start`, then the detected kind. The metadata `title` is the pane border. Shepherd, herdmgr, and the diagnosing tools were using `title ?? terminal_title_stripped ?? kind`. An agent the user named `reviewer` showed the OSC title instead, and four Claude panes with the same "Action Required" title stayed indistinguishable. An empty `title` or `foreground_cwd` was also a present string, so `"" ??` the real value blanked the name or the directory on the next poll.

The row now uses one chain: metadata title, then `display_agent`, then the rename, then the stripped terminal title, then the kind. Empty strings are absent. `pane_updated` and `pane_moved` do not carry `name`. The last `agent.list` that was allowed to update the pane remembers it, and a terminal title on the event does not replace it. A list that includes the pane and omits `name` clears it, so `agent rename --clear` shows the terminal title again. A list that leaves every name source off keeps the name the row already has. A new session drops the rename: herdr clears it when the owner changes, and the event has no `name` to put back. The same chain is what MCP prints.

Why this one: backlog items 1–29 stay deferred (below). This is the name in the menu bar and the live table, which is how you tell which agent needs you. The terminal title was covering the only stable label herdr's own panel shows.

Files:
- `Sources/HerdrManagerCore/Domain/Types.swift`
- `Sources/HerdrManagerCore/Domain/HerdSnapshot+Events.swift`
- `Sources/HerdrManagerCore/Domain/HerdSnapshot+Dwell.swift`
- `Sources/HerdrManagerCore/Store/AgentStore.swift`
- `Sources/HerdrManagerCore/Adapter/HerdrAdapter.swift`
- `Sources/herdr-manager-mcp/HerdrManagerMCP.swift`
- `Tests/HerdrManagerCoreTests/HerdSnapshotEventsTests.swift`
- `Tests/HerdrManagerCoreTests/HerdSnapshotDwellTests.swift`
- `Tests/HerdrManagerCoreTests/AgentStoreHerdTests.swift`

Self-review:
- Swift 6: `AgentLabel` is a stateless `Sendable` enum. The rename map is `@ObservationIgnored` on the `@MainActor` store, and a `[String: String]` on `HerdLiveTable`, which stays a `Sendable` value herdmgr mutates on the task that owns the event loop. `applying`'s new parameters default, so existing call sites keep their labels. No new macOS API, import, or isolation. `rememberAliases` runs on the store after the row is built and does not await.
- A list with `name` `reviewer` and terminal title "Action Required" shows `reviewer`. A metadata title still wins, and `display_agent` wins over the rename. An empty title does not blank a stripped title. An empty `foreground_cwd` does not blank a real `cwd`, and a list that leaves both off keeps the directory the row had.
- `pane_updated` with a new terminal title keeps `reviewer` and the dwell. A move carries the rename onto the new id. The next list that omits `name` and still has the terminal title shows that title. A list that omits every name source keeps the row's name. A different session shows the new terminal title and does not keep the rename.
- herdmgr: the same rename survives `pane_updated`. A poll that has already seen a pane the table has not drawn yet still names that pane from the rename when `pane_updated` inserts it. A move keeps the rename when no list has the new id yet. A refetch that already omitted `name` is not undone by that move. A new session does not keep the rename.
- A `pane_updated` that sets `display_agent` and a later move that omits it shows the rename again. The field is on the pane when herdr has one; an event that leaves it off is not a stored override. MCP's inventory and inspect text use the same chain.
- Not compiled and not run. No Swift toolchain on this box.

### Pass 31 — an empty herdr string is not an occupant or a directory

Pass 30 stopped an empty `title` or `foreground_cwd` from blanking the row. The write path still used `??`, so `""` counted as present. A session-less agent's fingerprint is `title ?? name ?? terminal title`. A cleared title made that string empty, and the next list that omitted the title used the rename. The two reads are the same occupant. The answer cap treats a fingerprint change as a new person and resets, and the confirm re-read refuses the write. A new tab or split had the same shape: `foreground_cwd ?? cwd` handed `""` to `tab.create` and `pane.split` and never reached the real directory. Omitting cwd is what already lets herdr choose one; an empty string is not that omission.

The fallback fingerprint now skips empty title, name, and terminal title, then uses the kind. A session fingerprint is unchanged, and `display_agent` stays out of the string: it is a presentation label, and fingerprints already stored on pending actions do not include it. `workingDirectory` is the nonempty foreground directory, then the nonempty cwd. Shepherd's New agent hints and MCP's new-tab and split placements use it, and a query matches that directory. `tab.create` and `pane.split` omit an empty cwd even if a caller still passes one. Inspect skips a blank directory line.

Why this one: backlog items 1–30 stay deferred (below). This is the write those empty fields were still reaching. The row already showed the rename and the real directory.

Files:
- `Sources/HerdrManagerCore/Domain/Types.swift`
- `Sources/HerdrManagerCore/Adapter/HerdrAdapter.swift`
- `Sources/ShepherdApp/AppModel.swift`
- `Sources/herdr-manager-mcp/HerdrManagerMCP.swift`
- `Tests/HerdrManagerCoreTests/PromptAnswerCheckTests.swift`
- `Tests/HerdrManagerCoreTests/AdapterTests.swift`

Self-review:
- Swift 6: both new values are computed properties on `HerdrAgentInfo`, a `Sendable` struct. `AgentLabel.nonempty` and `preferred` are stateless. `createTabParams` is a static function called the same way `splitPaneParams` already was, from the write closure on the serial I/O queue. No new isolation, macOS API, import, or protocol requirement. Callers that pass nil still omit cwd. A non-empty cwd is still sent.
- An empty title with name `reviewer` fingerprints as `fallback|codex|reviewer|pane`, the same as a missing title. An empty title and name fall through to the terminal title, and when that is empty too the kind is the label. A real title still leads the rename. A session fingerprint ignores the empty title. `display_agent` on that fixture is `codex` and is not the label. The re-read before the keys accepts the rename. A different terminal title, with no title and no name, still refuses. A gated say to the same rename accepts a later seq.
- `workingDirectory` is the foreground path when it is non-empty, the cwd when the foreground is `""` or missing, and nil when both are empty or missing. `pane.split` and `tab.create` drop `""` and still send `/work`. A label and a workspace id on that tab request are unchanged.
- A whitespace-only title or directory is still present. Trimming it would change a fingerprint already stored for that exact string (item 33). herdmgr's status poll still clears a crash when the episode changes and does not rescan until the next event or the 15s tick (item 31). `applySnapshot`, the old `session.snapshot` panes path, still uses `??`. The menu bar, herdmgr, and MCP build rows from `agent.list`. Nothing in those three calls `applySnapshot`.
- Not compiled and not run. No Swift toolchain on this box.

### Pass 32 — a status poll that opens an episode reads that row's process before it draws

herdmgr's 3s poll updates a row it already shows. A new seq, a new status, or a new session replaces the verdict with the status verdict. The process list was read on events and on the 15s tick, not on that poll, so a crash was cleared for the gap. A dead agent whose status string stayed `working` left the attention table: `GONE` is what makes a working row worth showing, and the default table hides a healthy working row. The next event, or the tick, could put the crash back. A poll of the same episode already kept it.

The poll now returns the ids whose episode opened. herdmgr reads the process list for those rows only, then draws. A bare shell stamps `GONE` on the new episode, so the row stays on the attention list. A same-episode poll, including one that only changes the title, returns nothing and is not read: that read would be the whole table at the herd cadence, and a running result would clear a crash the last scan had stamped. A pane the list does not contain is not an opened episode, so a move's new id does not make this poll scan the rows `pane.moved` still has to re-key. A failed herd read returns nothing. An empty process read does not copy the old crash onto the new episode. Done and idle are named when their episode opens, and the process read returns running before any socket call, so a finished agent is not marked gone.

Why this one: backlog item 31. Items 1–30 and 32–33 stay deferred. The deferral was the cost of `pane.process_info` for every row on every poll. The rows whose episode just opened are the ones whose crash was cleared.

Files:
- `Sources/HerdrManagerCore/Domain/HerdSnapshot+Dwell.swift`
- `Sources/herdmgr/Herdmgr.swift`
- `Tests/HerdrManagerCoreTests/HerdSnapshotDwellTests.swift`

Self-review:
- Swift 6: the return is `[AgentID]`. `AgentID` is `Hashable` and `Sendable`. `@discardableResult` keeps every existing call compiling. No new actor, isolation, macOS API, or import. herdmgr awaits the process read, then stamps the table. The table is not passed `inout` across that await. The id set is a local value. `observeProcessGone` was already on the `Diagnoser` actor.
- A title change at the same blocked seq returns nothing and keeps the crash. The other row, working seq 3 to done seq 9, is the only id returned, and a pane the list added is not. The next poll of those episodes returns nothing. A list that does not contain the shown ids returns nothing and leaves both rows. A list that omits the session returns nothing and keeps the crash. A different session returns that pane only and clears the crash. A failed poll returns nothing.
- A working row at seq 4, after a crash at seq 3, is not attention-worthy until the gone observation for that returned id is applied. The other row's crash is untouched. The following poll returns nothing and keeps the restored crash. An unknown observation leaves the new episode on the status verdict.
- herdmgr draws once, after that read. A poll that changes nothing does not draw. The 15s tick still reads the whole table, which is how a crash with no episode change is still found, and how an unknown read of a new episode is retried. A move during the poll is still the next event, and that event reads the table after it re-keys.
- Not compiled and not run. No Swift toolchain on this box.

### Pass 33 — a peek still loading after a move does not stay on Reading

The panel reads the pane id the click named, then shows the text only when the selection is still that id. A cross-workspace move, and a poll that already continued the session, point the selection at the new id while that read is in flight. The guard then drops the text and leaves the expansion on `peekLoading`. That spinner is drawn on the new row. Space and a second click both return immediately while it is up, so the peek never finishes and cannot be started again until the selection moves to some other row.

The finished read is applied only when it is still the latest peek and the spinner is still up. The same pane shows the text. A different selection reads that pane instead of showing bytes addressed to the id the agent left: after the move those bytes can be the shell now sitting there. No selection clears the spinner, so it cannot attach to whichever row is selected next. A newer peek, or a spinner the panel already closed by arrowing away, is left alone.

Why this one: backlog items 1–33 stay deferred (below). This is the menu bar's peek, stuck on the move those passes already follow for the highlight, the silence, and the detection hash. The read of the old id is still not shown.

Files:
- `Sources/HerdrManagerCore/Domain/PeekCompletion.swift`
- `Sources/ShepherdApp/PanelView.swift`
- `Tests/HerdrManagerCoreTests/PeekCompletionTests.swift`

Self-review:
- Swift 6: `PeekCompletion` is a stateless `Sendable` enum. `Decision` is `Equatable`. `AgentID` was already `Hashable` and `Sendable`. The generation is `@State` on the panel, read and written on the main actor with the expansion. The read task is the same shape as the one the panel already used. No new macOS API, import, or protocol requirement. `finishPeek` runs on the main actor after the read, and a reread calls `beginPeekLoad` only then, so the next generation is not started from inside the socket call.
- Same pane, still loading, latest peek: show. Selection moved to another id: reread, which is not show. Selection nil: clear. A newer peek ignores the older result even when the selection moved or stayed. A spinner already closed ignores the result, including when the selection is now the moved id, so a peek the user arrowed away from is not opened on that row.
- The panel bumps the generation before the read. The move's retarget and the poll's session continuation both change `selectedAgentId` without closing the expansion; user selection and the arrow keys close it first. A reread whose pane is no longer in the store, or whose stored id is still the one just read, clears the spinner instead of reading that id again. A second move during the reread takes the same path. A peek that already showed its text stays put when the selection follows a later move: that text was read before the move, from the pane the agent was on.
- The loading click is still ignored. The reread is what makes the spinner finish. herdmgr and MCP do not peek.
- Not compiled and not run. No Swift toolchain on this box.

### Pass 34 — a relaunch does not give a new session the previous occupant's dwell

The dwell file matched a reused pane on kind, status, and a non-zero seq. `agent_session.value` was parsed and kept beside the row, and the live herd already opens a new episode when that value changes. The file did not. After Shepherd quit, a different session in the same pane, still blocked at the same seq, came back with the previous person's "blocked for 2 hours." Putting the session into the settings fingerprint would have changed every override key.

The session is stored on the row and, when the pane has one, in the dwell file, beside the kind fingerprint. A file and a live row that both name a session restore only when those strings are equal. A file written before this field existed has none, and still matches on kind and seq. A live row whose list left the field off still takes that dwell: omitting it is not a new person. The restore then remembers the file's session on the row, so the next list that names a different one opens a new episode instead of looking like the first session this pane has ever had. A row that already named a different session does not take the file's clock. Empty is still not an identity. The settings key is still the kind.

Why this one: backlog item 2. Items 1, 3–33 stay deferred. This is the dwell the menu bar shows after a relaunch, which the live-row rule already protected and the file did not.

Files:
- `Sources/HerdrManagerCore/Domain/Types.swift`
- `Sources/HerdrManagerCore/Store/AgentStore.swift`
- `Sources/HerdrManagerCore/Domain/HerdSnapshot+Events.swift`
- `Sources/HerdrManagerCore/Domain/HerdSnapshot+Dwell.swift`
- `Sources/HerdrManagerCore/Dwell/DwellTracker.swift`
- `Sources/herdr-manager-mcp/HerdrManagerMCP.swift`
- `Sources/ShepherdApp/AppModel.swift`
- `Tests/HerdrManagerCoreTests/DomainTests.swift`
- `Tests/HerdrManagerCoreTests/AgentStoreHerdTests.swift`
- `Tests/HerdrManagerCoreTests/HerdSnapshotDwellTests.swift`

Self-review:
- Swift 6: `sessionIdentity` is a `String?` on `Agent`, a `Sendable` struct, and on `DwellEntry`. `SessionIdentity.carried` is a stateless function. The store writes it on the `@MainActor`, in the same place it already writes `sessionByPane`. `DwellTracker` stays `@unchecked Sendable`; the new field rides inside the entry the lock already covers. No new isolation, macOS API, or import. `Agent.==` includes the field, so learning a session publishes the row. The initializer parameter defaults to nil, so every existing `Agent(...)` and `DwellEntry(...)` still compiles. Synthesized `Codable` treats the optional as `decodeIfPresent` / `encodeIfPresent`: a file with no key decodes, and a save with no session omits the key.
- The kind fingerprint is unchanged. `DwellTracker.fingerprint` and `AppModel.fingerprintForAgent` still switch on kind only, so a settings override keyed by `claude` or `custom:claude` still finds the same row.
- Same kind, status, and seq: session `abc` restores its `enteredAt`; session `other` restores nothing. A file with no session key still restores onto a row that has one. A row that has not named a session still takes the file's dwell, and the entry keeps `abc`.
- The store: a list that omitted the session, then a restore of `abc`, keeps that dwell when the next list names `abc` and opens a new one when it names `other`. A row already on `other` does not take `abc`'s clock or its session. A seq-less `pane_updated` and a seq-less move that omit the field keep the session on the row. herdmgr's layout refetch and status poll do too, and the event that names the next session replaces it.
- A pane that never had a session, and a file from before this pass, still match on kind and seq. Two session-less occupants at the same seq are still the one episode. A restart that comes back with the same session and the same seq is still that episode: herdr has no instance id to tell them apart.
- Not compiled and not run. No Swift toolchain on this box.

### Pass 35 — an empty session is not an occupant, and it is not a kind

`agent_session` with `value: ""` is not an identity. `sessionIdentity` already returned nil, and a move would not follow it. `occupantFingerprint` still took the session branch whenever the object was present, so the title was ignored. Two session-less occupants in one pane compared equal, and a list that included the empty object disagreed with one that left it off. MCP `agent.answer` then either sent the keys or refused them, and the answer cap reset, on a field herdr uses for "no native session." A value that is only whitespace stays an id.

The same object with `agent: ""` — the parser's default when the key is missing — became `AgentKind.custom("")`. That is a different settings fingerprint from the detected kind, and a blank kind in the menu bar, herdmgr, and MCP. `pane_updated` on the live table already fell back when the string was empty. The list, the store, the move, and MCP did not. `AgentKind.resolved` is that rule everywhere. A named session agent still wins. Approve still compares kind when the click captured no session (item 28); it does not compare this fingerprint.

Why this one: backlog items 1–33 stay deferred. Item 2 is done. This is the write identity those items already refuse to treat as a person, still deciding whether the keys go out.

Files:
- `Sources/HerdrManagerCore/Domain/Types.swift`
- `Sources/HerdrManagerCore/Store/AgentStore.swift`
- `Sources/HerdrManagerCore/Domain/HerdSnapshot+Events.swift`
- `Sources/herdr-manager-mcp/HerdrManagerMCP.swift`
- `Tests/HerdrManagerCoreTests/PromptAnswerCheckTests.swift`
- `Tests/HerdrManagerCoreTests/HerdSnapshotEventsTests.swift`
- `Tests/HerdrManagerCoreTests/AgentStoreHerdTests.swift`

Self-review:
- Swift 6: `AgentKind.resolved` is a static method on a `Sendable` enum. It calls `AgentLabel.nonempty`, which is stateless. `occupantFingerprint` still returns a `String` from a `Sendable` struct. No new isolation, actor, macOS API, or import. A non-empty session value still formats as `session|<identity>|<paneId>`, which is the same string as `session|source|agent|kind|value|paneId`, so stored pending-action fingerprints and `fingerprintBelongs` do not change. Callers that already held a non-empty `detected` kind pass it through; `applySnapshot` uses `"unknown"` only when the pane named neither.
- Empty value, title `Review`: the fingerprint matches a missing session and is `fallback|codex|Review|wA:p1`. `agent.answer` allows that re-read and refuses title `Other`. An all-empty session object does the same. A value of one space stays `session|agent|claude|session| |wA:p1`.
- Confirm-tier follow and a gated say accept the same title on the same pane, including a re-read that omitted the object, and still refuse a different title and a move. A real session value still follows and still ignores the title.
- Kind: a blank session object keeps `.custom("claude")` on `displayAgent`, on `pane_updated`, and on a seq-less move, in the store and in herdmgr's table. The settings fingerprint stays `custom:claude`. A session whose agent is `codex` is still that kind. MCP inspect prints the detected kind instead of a blank source when the object names nothing.
- Not compiled and not run. No Swift toolchain on this box.

### Pass 36 — an OpenCode row still receives usage from every provider

The usage meter treats OpenCode as one CLI that can run several model providers, so a priced event in its directory belongs to that pane whatever the log says. The check was `kind == .opencode`. The herd does not store that case. `AgentKind.resolved` wraps the runtime in `.custom` so a Claude row's settings fingerprint stays `custom:claude`, and an OpenCode row is `.custom("opencode")`. The label is still `opencode`. The enum comparison missed it: those events attributed to nobody, and a Claude event in the same directory was no longer ambiguous, so it landed on the Claude pane alone. Claude and Codex themselves were unaffected, because the provider map already uses the label.

The meter now matches that label, which is also what `.opencode` and `.custom("OpenCode")` produce. A shared directory stays ambiguous for a Claude event and still gives a Codex event to the OpenCode pane. A directory with only that pane receives the Claude event. The settings key is unchanged. Mapping the row to the enum case would have turned `custom:opencode` into `opencode` and dropped the override and the saved dwell.

Why this one: backlog items 1–34 stay deferred (below). This is the usage dashboard for a runtime the herd actually stores, reading as if the pane had no log.

Files:
- `Sources/HerdrManagerCore/Usage/TokenMeterTypes.swift`
- `Sources/HerdrManagerCore/Usage/TokenMeterReader.swift`
- `Tests/HerdrManagerCoreTests/TokenMeterTests.swift`

Self-review:
- Swift 6: `matchesAnyUsageProvider` is a static method on `TokenMeterProvider`, a `Sendable` enum. It reads `AgentKind.label`, a synchronous value. The aggregator is a struct and calls it while building candidates, before any event is folded. No actor, no new isolation, no macOS API, no import. The failable provider init is still the other branch, so a `.custom("claude")` row still maps to the Claude log.
- `.opencode` still matches every provider. `.custom("opencode")` and `.custom("OpenCode")` do too. `.claude` and `.custom("claude")` do not. In a shared directory the two Claude events stay ambiguous and the Codex event's 40 input tokens stay on the OpenCode pane. Alone, that pane receives the Claude event's 100.
- A kind that is only whitespace, or that merely contains the word, still does not match. That is the same absence rule as a title (item 33). The fingerprint for the live row stays `custom:opencode`.
- Not compiled and not run. No Swift toolchain on this box.

### Pass 37 — the MCP list prints the pane id other tools accept

`herd.overview` and `agent.list` printed `AgentID.paneId`. For herdr's `w1:p1` that is `p1`. Inspect, diagnose, tail, and every write match `HerdrAgentInfo.paneId`, which is the whole `w1:p1`. A caller that copied the bracket or the Pane column looked an agent up and missed, and two workspaces that both had a `p1` could not be told apart. The list also truncated that column at 8 characters, so `w100:p1000` became a string that is not an id.

The row now shows `AgentID.raw`, untruncated, with a line that says that value is the `agent_id`. Read tools still accept a local suffix when exactly one listed pane has it, which is the id an older overview printed. Two matches name both full ids and pick neither. An exact id still wins over a pane whose own suffix is that whole string. A blank id is not a lookup, so the query runs only then. Writes still require the full id: the answer cap, the confirm fingerprint, and `explain` are all addressed with the string the caller passed, and a suffix would store that budget on the wrong key.

Why this one: backlog items 1–35 stay deferred (below). This is the id a model copies out of the first tool it calls, and then cannot use.

Files:
- `Sources/HerdrManagerCore/Domain/HerdReport.swift`
- `Sources/HerdrManagerCore/Domain/HerdSnapshot+Resolve.swift`
- `Sources/herdr-manager-mcp/HerdrManagerMCP.swift`
- `Tests/HerdrManagerCoreTests/HerdReportTests.swift`

Self-review:
- Swift 6: `HerdReport` and `AgentResolution` are `Sendable`. The report functions are static and touch no actor. `resolveAgent` is a method on the `Sendable` snapshot and returns a `Sendable` enum. MCP calls both from the server actor with values it already holds. No new isolation, macOS API, or import. `kindText` keeps the stored custom spelling, so the list and its filter still agree; `AgentKind.label` lowercases that string and would have changed the filter.
- Overview of `w1:p1`, `w2:p1`, and `w100:p1000` contains each full id in brackets and does not contain `[p1]`. The crashed row is still `GONE`. The list contains `w100:p1000` whole, not `w100:p1…`, and the column is `ID`. An empty herd keeps the same two sentences. `.custom("Claude")` still prints `Claude`.
- `w1:p1` resolves to that pane even when another pane's suffix is the same string and the query names the other pane. `p10` with surrounding spaces resolves to `w1:p10` and does not take `w1:p1`. `p2` is not found, and a query passed beside it is ignored. `p1` on both `w1:p1` and `w2:p1` fails and names both full ids in order. A query for one title still finds that pane. A blank id falls through to the query. A query of only spaces, and a query that matches nothing, keep the old errors.
- Not compiled and not run. No Swift toolchain on this box.

### Pass 38 — a blocked prompt herdr already named is not an unknown block

`BlockKind.from` knew eight rule ids. The manifests herdr ships now block on many more, and an unmapped id is `.unknownBlock`. The menu then says "unknown block", and MCP `agent.answer` sends nothing: unknown and probable prompts stay read-only. OpenCode's only blocked rule is `permission_required` ("enter confirm" / "esc dismiss"). Gemini's only one is `apply_or_allow_change`. Codex `trust_directory` outranks the generic enter/esc rule, so a trust prompt that would have been an approval was unknown instead. The same hole covered Claude's MCP elicitation dialog, Kimi's confirm panel, and the enter-to-select menus.

Those screens are `.confirmation`: approve is Enter, deny and cancel are Esc, and select moves to a row. `accept_once` (Down, then Enter) stays on the yes / don't-ask-again / no stack. The next row of a confirmation is not that remembered yes — on the elicitation dialog it is Decline. Rules that say Enter selects stay `.selectionForm`, which already had those keys. A block whose key is `y` or Ctrl+C, or whose id is shared by screens that disagree, is `.probableApproval` and still sends nothing. `permission_prompt` is one id for three agents, and on one of them Enter denies. A password prompt and a shell waiting for input stay unknown, so Enter is not offered there either.

Why this one: backlog items 1–36 stay deferred (below). This is the "needs you" line and the only MCP write that answers a prompt, still treating the block herdr named as if it had no shape.

Files:
- `Sources/HerdrManagerCore/Domain/Types.swift`
- `Sources/herdr-manager-mcp/HerdrManagerMCP.swift`
- `Tests/HerdrManagerCoreTests/DiagnosisTests.swift`

Self-review:
- Swift 6: `BlockKind` stays a `Sendable` raw-value enum. `answerKeys` is a synchronous method on that value. The MCP actor calls it and does not cross an isolation boundary. No new macOS API, import, or stored field. The new case's raw value is `confirmation`. Nothing persists a `BlockKind`, so an older file does not have to decode it. The summary switch and `answerKeys` both name the new case. A negative `select` index returns nil; `Array(repeating:count:)` traps on a negative count, and the old helper would have.
- OpenCode, Gemini, the Codex trust and update prompts, and the other enter-to-confirm ids map to `.confirmation`. Approve is Enter, deny is Esc, `accept_once` is nil, and select of 2 is Down, Down, Enter. The enter-to-select ids stay `.selectionForm` with the same refusal of `accept_once`. `permission_prompt`, the Cursor `y` prompts, and the Grok screens whose cancel is not Esc are `.probableApproval` and every choice is nil. `credential_prompt` and `confirmation_or_input_blocker` stay `.unknownBlock`. Bash, tool, approval, and workflow still take `accept_once`. A menu select with no index is Enter.
- The menu-bar Approve button still sends Enter for every block, including probable and unknown. It does not read the matched rule. `osc_title_blocked` is still `.approval` for every agent that shares that id.
- Not compiled and not run. No Swift toolchain on this box.

### Pass 39 — a pane rename is the row's name

`herdr pane rename` stores `PaneInfo.label`. `session.snapshot` panes carry it. `agent.list` does not, and a pane rename does not emit `pane.updated`, so the menu, herdmgr, and MCP kept showing the terminal title. Two panes the person had named still looked like the same agent.

The name is still the metadata title, then `display_agent`, then `herdr agent rename`, and the pane label now comes before the terminal title. A herd read that lists the pane is the clear: no label, and a terminal title or rename still on the row, shows that instead. A read that was built without pane ids does not clear. An event that includes `label` shows it immediately and keeps it across a later title-only `pane_updated`. An event that omits `label` does not clear it, so a partial payload cannot blank a name the snapshot has not caught up to. A move carries the label. A new session does not drop it: the label names the pane, and herdr does not clear it when the agent changes. The occupant fingerprint does not include it. MCP's query matches it. A label that is only whitespace is still a label.

Why this one: backlog items 1–39 stay deferred (below). This is the name on the row the person is scanning, still ignoring the name they set on the pane.

Files:
- `Sources/HerdrManagerCore/Domain/Types.swift`
- `Sources/HerdrManagerCore/Domain/HerdSnapshot+Events.swift`
- `Sources/HerdrManagerCore/Domain/HerdSnapshot+Dwell.swift`
- `Sources/HerdrManagerCore/Domain/HerdSnapshot+Resolve.swift`
- `Sources/HerdrManagerCore/Store/AgentStore.swift`
- `Sources/HerdrManagerCore/Adapter/HerdrAdapter.swift`
- `Sources/herdr-manager-mcp/HerdrManagerMCP.swift`
- `Tests/HerdrManagerCoreTests/AdapterTests.swift`
- `Tests/HerdrManagerCoreTests/HerdSnapshotEventsTests.swift`
- `Tests/HerdrManagerCoreTests/HerdSnapshotDwellTests.swift`
- `Tests/HerdrManagerCoreTests/AgentStoreHerdTests.swift`
- `Tests/HerdrManagerCoreTests/HerdReportTests.swift`

Self-review:
- Swift 6: `paneLabel` is a `String?` on the `Sendable` agent info, defaulted so existing initializers stay source-compatible. `HerdSnapshot.paneLabels` and `snapshotPaneIds` are defaulted the same way. The live table's map is a value-type dictionary on the `Sendable` table. The store's map is `@ObservationIgnored` on the `@MainActor` store. No new actor, isolation, macOS API, or import. `==` on `HerdrAgentInfo` still ignores the field, the same way it ignores `agentSession`; the row's name is what the panel compares.
- A snapshot label `api` with a terminal title `Action Required` is the row's name. A metadata title and an agent rename still win. An empty label is absent. A whitespace label is kept. The occupant fingerprint of an empty label matches the fingerprint without one.
- A title-only `pane_updated` keeps `api` and the dwell. A move onto a new id keeps `api`. A snapshot that lists the new id and omits the label shows the terminal title instead, and does not copy the old id's label back. A later snapshot that names `api` again shows it. A different session keeps `api` and opens a new dwell. herdmgr's table does the same, including a status poll that clears and a poll that puts the label back without opening a dwell.
- The parser: a later duplicate pane wins, `""` is a clear, `" "` is a label, and `pane_updated` with `label` stores it. A query for that label resolves to the pane.
- A herd read captured before a rename, and applied after an event that already showed the new label, puts the pre-rename name back until the next read. herdr does not emit on `pane rename`, so the snapshot is the first observation. A cleared label still sticks when the row also has no title, rename, display agent, or terminal title (item 40).
- Not compiled and not run. No Swift toolchain on this box.

### Pass 40 — a crashed pane is not counted as running

herdr keeps the last status after the process dies. The menu bar, the footer, and `AttentionTriage.kind` already call that gone. The panel's Running tab and the header next to it still asked `status == .working` and `status == .done`. A dead worker stayed in Running, and the header counted the same pane as needing you and as running. A crash on a finished pane was counted as done as well. A quiet worker is still running: silence is a clock on a live process, not an exit, and the Running tab was already showing that row.

`isRunning` is the working status without a process-gone verdict. `isFinished` is the exclusive done bucket, which a crash already outranks. The tab, its count, and the header's running figure share `isRunning`, so they cannot drift. The done figure uses `isFinished`.

Why this one: backlog items 1–40 stay deferred for the reasons already recorded. This is the Running list, still trusting the status string pass 13 stopped trusting on every other surface.

Files:
- `Sources/HerdrManagerCore/Domain/AttentionTriage.swift`
- `Sources/ShepherdApp/PanelView.swift`
- `Tests/HerdrManagerCoreTests/AgentStoreHerdTests.swift`

Self-review:
- Swift 6: both predicates are static methods on the `Sendable` enum. They read `status` and `verdict` on a value. `isFinished` calls `kind`, which is the same enum. The panel calls them from the view that already reads the `@MainActor` store. No new isolation, actor, macOS API, or import. `kind`'s process-gone arm is first, so a crash is neither running nor finished.
- A working crash is not running and still needs you. A done crash is not finished and not running, and still needs you. A quiet worker is running and needs you. A healthy worker is running and does not need you. A healthy done pane is finished and does not need you. A blocked pane, including a crashed one, is not running.
- The Running rows and the header tally both call `isRunning`. A search match does not put a crash back: the count loop and the list use the same predicate after the same search. `isFinished` matches `kind == .done`, which the existing crash tests already place outside done.
- The menu-bar spoken summary still uses `counts.working`, which excludes silence as well as crashes. That sentence only speaks when nothing needs you, so a quiet herd is announced as silent rather than as working. The panel's Running tab is the list of live workers, quiet included.
- MCP `agent.list` `status=working` still returns a crash (item 41). A quoted JSON secret is still not redacted (item 42). The row's active ring still brightens for a working crash, because `active` is the status (item 43).
- Not compiled and not run. No Swift toolchain on this box.

### Pass 41 — a quoted JSON assignment is redacted

`agent.tail`, diagnose, and the other MCP reads scrub pane text before it reaches the model, then scrub that result again on the way out. The generic pattern required `=` or `:` immediately after `api_key`, `secret`, `token`, or `password`. A JSON key has a quote in between (`"api_key": "…"`), so the value left intact. A quoted passphrase also left intact: the value pattern stopped at the first space, and `correct` is shorter than the 8-character floor, so nothing was removed.

The name may now have a quote before the separator. A double-quoted value is the whole string, including spaces and apostrophes, and a single-quoted value is the whole string, including spaces. The closing quote is not consumed. An unquoted value is still one token. A value that is already `xai-[REDACTED]` or `[REDACTED]` is not a second secret. `access_token` and `client_secret` still match as suffixes, and the prefix stays on the label.

Why this one: backlog item 42. Items 1–41 and 43 stay deferred for the reasons already recorded. This is the secret those tools were built to strip, in the shape a config dump and a curl body actually use. The menu bar's peek is the owner's own screen and does not run this scrubber.

Files:
- `Sources/HerdrManagerCore/Redaction/SecretRedactor.swift`
- `Tests/HerdrManagerCoreTests/DomainTests.swift`

Self-review:
- Swift 6: no new type, isolation, or API. The pattern is still a static `NSRegularExpression` on the `Sendable` redactor. `$1` is still the key-name group. The three value alternatives are non-capturing, and the placeholder interpolated into each lookahead adds none, so a second capturing group cannot shift the replacement. `try?` still drops a pattern that does not compile. Dropping this one would also drop `token=`, which the existing exact test requires. No new macOS API.
- The closing quote stays because MCP redacts twice. The placeholder is only a placeholder when the next character is the end, whitespace, a quote, or `&`. A `}` is not that boundary. Consuming the quote would leave `}` against `[REDACTED]`, the second pass would count the placeholder as a new value, and the brace would disappear. Leaving the quote means the second pass sees the boundary it already had for `token=[REDACTED]`.
- Walked: `{"api_key": "…", "token": "…"}` becomes `{"api_key=[REDACTED]", "token=[REDACTED]"}` with count 2, and the second pass is 0. No space, single quotes, a space before the colon, and a newline or CRLF before the value do the same. `token="…"` and `token='…'` still leave the closing quote. A double-quoted passphrase with an apostrophe is one redaction and the words are gone; the single-quoted passphrase with spaces is too. `access_token` and `client_secret` keep their prefixes. `apiKey` and `api-key` both match. A recognized `xai-` value inside `"api_key"` stays `xai-[REDACTED]` and counts once, and the sibling generic token still redacts. `{"name", "status", "max_tokens"}` is unchanged, including an 8-digit `max_tokens` count. A 7-character quoted value stays. An 8-character one is redacted. `"token": "[REDACTED]"` counts 0. Prose with no separator counts 0. The existing `XAI_API_KEY=xai-…` line is still exactly `xai-[REDACTED]` counted once, and the env double-redact test is unchanged.
- A name that continues after the keyword still leaks: `secret_key` and `AWS_SECRET_ACCESS_KEY` (item 44). A backslash-escaped quote, or a newline inside the quoted value, still ends the value. An unquoted value is still one token. A singular `max_token` before an 8-digit number matches, because the keyword is still an unanchored suffix; `max_tokens` does not. The same regex was checked with Python's `re`, which is not ICU. `NSRegularExpression` uses ICU. The pieces added are a non-capturing group, quotes, and `[^"\n]` / `[^'\n]`, around the same `(?!placeholder)` this pattern already compiled.
- Not compiled and not run. No Swift toolchain on this box.

### Pass 42 — secret_key and AWS_SECRET_ACCESS_KEY are redacted

The generic assignment matched `secret` only when that word was the end of the name. `secret_key` and `AWS_SECRET_ACCESS_KEY` continue past it, with `_key` or `_access_key` where a separator would be, so the value reached the model. Those two endings are now part of the name. A hyphen is the same separator `api_key` already accepts (`secret-key`, `secret-access-key`). The match still has to end there: `secret_name`, `secret_keys`, `token_count`, and `AWS_SECRET_ACCESS_KEY_ID` stay, which is the over-redaction a broad `[_-]word` suffix would have caused. The closing quote stays, so a second pass still sees a placeholder boundary. A recognized `xai-` value inside `secret_key` keeps that label and counts once. The captured name keeps its case, and a prefix before `secret_key` stays on the label.

Why this one: backlog item 44. Items 1–43 and 45–46 stay deferred for the reasons already recorded. This is the secret those tools were built to strip, in the env name and the JSON key a config dump actually uses.

Files:
- `Sources/HerdrManagerCore/Redaction/SecretRedactor.swift`
- `Tests/HerdrManagerCoreTests/DomainTests.swift`

Self-review:
- Swift 6: no new type, isolation, or API. The pattern is still a static `NSRegularExpression` on the `Sendable` redactor. The new alternative sits inside the existing capturing group. `(?:[_-]access)` adds no capture, and the value alternatives and the placeholder lookahead add none, so `$1` is still the whole name. `try?` still drops a pattern that does not compile. Dropping this one would also drop `token=`, which the existing exact test requires. No new macOS API.
- The compound name is listed before bare `secret`, so `SECRET_ACCESS_KEY` is captured whole on the first try. Bare `secret` still matches `client_secret` and `SECRET=`, because the compound alternative needs `_key` or `-key` and fails closed when the next character is `=` or the end of a different word.
- Walked: `SECRET_KEY` and `AWS_SECRET_ACCESS_KEY` (value containing `+` and `/`) become those names with `=[REDACTED]`, count 2, and the second pass is 0. The JSON object redacts `aws_secret_access_key` and `secret_key`, leaves `secret_name` and `token_count`, and the second pass is 0. Hyphen forms, `my_secret_key`, an 8-character value, and `Secret_Access_Key` keep the prefix and the case. A quoted passphrase with an apostrophe is one redaction. `secret_name`, `secret_keys`, `AWS_SECRET_ACCESS_KEY_ID`, `secretary`, `token_count: 12345678`, a 7-character value, and a JSON `secret_name` count 0. `{"secret_key": "xai-…"}` stays `xai-[REDACTED]` and counts once. The existing `api_key`, `token`, `access_token`, `client_secret`, `apiKey`, password, `max_tokens`, and double-redact cases still hold.
- A backslash-escaped quote, or a newline inside the quoted value, still ends the value (item 45). `private_key` and `password_key` still leak: they are not a continuation of `secret` (item 46). The same regex was checked with Python's `re`, which is not ICU. `NSRegularExpression` uses ICU. The pieces added are a non-capturing group and `[_-]`, both of which this pattern already compiled.
- Not compiled and not run. No Swift toolchain on this box.

## Backlog / ideas

Pass 42 re-checked items 1–46. The ones still open stay deferred for the reasons already recorded. Item 2 is done. Item 6 is done for the move and for a status that leaves idle or done. Item 25 is done. Item 17 still applies to herdmgr's silence classification; the live table does now take title, kind, directory, and a known tab from `pane_updated` (pass 27), and a 3s poll updates status for an id it already shows (pass 29). MCP's diagnosing tools keep the episode clock (pass 21) and a slower earlier herd read no longer rewinds it (pass 24). Item 20's send still refuses because explain was addressed to the old pane; the cap follows the session. Item 26 is unchanged: the prefix check is still only applied to fingerprints stored on that same budget key. Item 27 is the limit of the MCP clock. Item 28 is the Approve path that captured no session. The live row opens a new episode when both the stored session and the incoming one are non-empty and differ (pass 25). A list or layout refetch that omits the session keeps that stored occupant (pass 26), so the next person still opens an episode. A relaunch now refuses a dwell whose stored session and the live row's session are both non-empty and differ (pass 34). A file with no session, and a live row whose list left the field off, still match on kind and seq; the restore remembers the file's session so the next different one opens an episode. The settings fingerprint is still the kind. A workspace or tab rename now applies from the event (pass 28). A list captured before that event does not put the old label back. herdmgr's status poll does not add or remove rows (item 29). A rename from `herdr agent rename` or `agent start` now labels the row ahead of the terminal title, and a later `pane_updated` does not put that title back (pass 30). A list that includes the pane and omits `name` clears it. A list that leaves every name source off keeps the name the row already has (item 30). An empty title, name, or terminal title is no longer a session-less occupant, and an empty foreground directory is no longer the cwd a new tab or split starts in (pass 31). `display_agent` stays out of that fingerprint (item 32). A whitespace-only title or directory is still present (item 33). herdmgr's status poll reads the process list for a row whose episode just opened, so a crash is stamped again before the table is drawn (pass 32). A same-episode poll still does not. A peek that is still loading when the selection follows a move reads the new pane instead of keeping the spinner up, and it does not show the bytes read from the id the agent left (pass 33). An `agent_session` whose value is `""` is the fallback occupant, same as a missing session when the title agrees, and a different title refuses the write (pass 35). An empty session agent is not a kind: the row keeps the detected kind, so the settings fingerprint does not become `custom:` (pass 35). A whitespace-only session value is still an id. The usage meter matches an OpenCode row by its label, so `.custom("opencode")` receives events from every provider the way `.opencode` does, and the settings fingerprint stays `custom:opencode` (pass 36). A kind that only contains that word, or is only whitespace, still does not match. `herd.overview` and `agent.list` now print the full pane id other tools accept (pass 37). A local suffix is accepted on the read tools only when one pane has it. Writes still require that full id. A blocked rule whose screen says Enter accepts the highlighted row and Esc cancels is a confirmation: MCP approve sends Enter, deny sends Esc, and `accept_once` is refused (pass 38). Enter-to-select rules stay a selection form. A rule whose key is `y` or Ctrl+C, or whose id is shared by screens that disagree about Enter, is a probable approval and still sends nothing. `permission_prompt` is that shared id, and on one agent Enter denies. A password prompt and a shell waiting for input stay unknown. The menu-bar Approve button still sends Enter for every block (item 37). `osc_title_blocked` is still an approval for every agent that shares the id (item 38). `herdr pane rename` is now the row's name, after the metadata title, `display_agent`, and `herdr agent rename`, and ahead of the terminal title (pass 39). A snapshot that lists the pane and omits the label clears it when another name is still present. An event that omits `label` does not. A move carries it, and a new session does not drop it. A cleared label with no other name still sticks (item 40). The occupant fingerprint does not include it. The panel's Running tab and its header no longer treat a process-gone `working` pane as running, and a process-gone `done` pane is not counted as finished (pass 40). A quiet worker stays in Running. MCP `agent.list` filtered by herdr's `status=working` still includes a crash (item 41). A quoted JSON assignment is redacted, including a passphrase with spaces or an apostrophe, and a second pass does not count it again (pass 41). `api_key=` and `token:` are unchanged. `secret_key` and `secret_access_key` (the suffix of `AWS_SECRET_ACCESS_KEY`, including a hyphen in either position) are assignments, and a second pass does not count them again (pass 42). The name still has to end there: `secret_name`, `secret_keys`, `token_count`, and `AWS_SECRET_ACCESS_KEY_ID` stay. A backslash-escaped quote, or a newline inside the quoted value, still ends the value early (item 45). `private_key` and `password_key` are still not redacted (item 46). The row's active ring still follows the status string (item 43).

1. A seq-less `pane_updated` that arrives after a poll already applied a newer status still flips the pane. The event carries no seq, so it cannot be told apart from a genuine second prompt. Deferred again: any rule that drops a seq-less status change also drops the live update the subscription exists to deliver. A non-zero seq is already ignored when it is behind the stored one.
2. Done in pass 34. The dwell file stores the session beside the kind fingerprint. A relaunch restores the clock only when a session named on both sides is the same string. A different session does not inherit the dwell. A file written before the field existed has none, and still matches on kind, status, and a non-zero seq. A live row whose list left the field off does too, and the restore writes that session onto the row, so the next different one opens an episode. The settings key is still `DwellTracker.fingerprint` / `AppModel.fingerprintForAgent`, kind only. What remains: a pane that never had a session, and a restart that comes back with the same session at the same seq. herdr has no instance id for the second, and an empty value is still not an occupant.
3. `paneBasis` keeps a tombstone for a pane a status, presence, or move event touched, including the previous id after a cross-workspace move, so a late pre-event list cannot resurrect it. Pane ids are not reused; the map grows with ids seen this launch. Deferred: one or two structs per moved pane per launch is not worth a pruning rule that might drop a basis an in-flight read still needs.
4. A herdr restart that reuses a pane id and comes back at the same `state_change_seq` with the same occupant fingerprint does not reset the 3-answer cap. Deferred: that read looks exactly like a second observation of the episode the cap is counting. Resetting on an equal seq would let a stale read clear the cap, which the policy test forbids. A lower seq, or the same seq with a new occupant fingerprint on the same budget key, does reset. A different session identity is its own budget (pass 18). A title that is `""` is the same fallback fingerprint as a missing title when the name or terminal title agrees (pass 31). An `agent_session` whose value is `""` is that same fallback, not a session fingerprint (pass 35).
5. Done in pass 7. A connect failure, a refresh that fails, and a dropped subscription clear the protocol under the enqueue epoch. A herd read that already started cannot record over that clear. A read that starts afterwards still can. `setLatestProtocol` with a nil epoch still bypasses that floor; no request path calls it that way.
6. Done in pass 22. A gated `agent.say` lists the herd again after the policy check and addresses that list. The original pane wins when it is still the same occupant. A different occupant sends nothing and does not take a slot. A pane that is no longer an agent follows a unique session, and only while that pane is still idle or done. `prompt` submits Enter, so a block or a working agent in the gap does not receive it. Idle and done still receive the text when the seq changes. An empty session value does not follow, and `abc` versus `abc|extra` does not either. A move during `reserveWrite`, after that list, still addresses the id the list named. That write is already queued.
7. `HerdrAgentInfo.==` does not compare `agentSession` (`AgentSession` is not `Equatable`) or `paneLabel`. `AnswerSendCheck` uses the fingerprint, not `==`. The store, the snapshot merge, and the write path do not branch on `HerdrAgentInfo` equality, so the missing fields do not change behavior today. Deferred: making `AgentSession` equatable is safe, and still has no caller. The row's name is what a pane-label change updates.
8. Done in pass 8. herdmgr's layout refetch no longer leaves a moved pane on a fresh dwell. The move copies the pre-refetch `enteredAt` onto the new id when status and seq still match, including when several panes move in one burst. A refetch after one of those moves has been applied starts a new baseline; a later move whose previous id is only on the old baseline keeps the reset dwell. A status or seq change is not restored. Shepherd still does not refetch on those events.
9. A seq-less `pane_moved` does not adopt a status that appears only on that payload. Deferred: `PaneInfo` has no seq, so a live status and a replayed one are the same bytes. Applying the payload status is what made a protocol-17 buffer replay reopen a blocked episode. `pane.updated` and Shepherd's poll still carry status. herdmgr still ignores the status on that payload. Once the row is on the id the table shows, the 3s poll applies the list's status (pass 29). A status that exists only inside the move waits for that poll, or for `pane_updated`.
10. A seq-less `pane_moved` with no agent still drops a row whose id matches. A replayed same-id move-to-shell can remove an agent that started in that pane later. Deferred: a live move to a shell has the same shape, and leaving the row would stick in herdmgr. Shepherd's next poll inserts the agent again.
11. A mutation already queued ahead of the snapshot that records a downgrade still runs. Deferred: the I/O queue is serial, and that write started when the gate was still open. Waiting for a read that has not been enqueued would stall every keystroke on a snapshot nobody requested. Pass 9 refuses the write once the downgrade's transaction is ahead of it.
12. Done in pass 11. The last usage event stays out of the history fold, with the unterminated tail. A Claude message that is still the last usage line keeps its id when a week or month boundary folds the older lines, and the next copy replaces it. The older lines in that session still fold.
13. A repeated Claude usage line that is no longer the last usage event can still be folded and then counted twice. An edit of bytes behind the resume signature is still unseen. Deferred: both sit behind a newer line, or behind bytes the append reader does not visit. Keeping every id that has ever been last would stop the older history from folding.
14. Done in pass 12. A silence measured at the start of a diagnosis pass is measured again on the row as it is when the verdict lands. Output inside the threshold leaves the pane healthy, including a quiet it was already showing. The heartbeat's newer output time clears that quiet immediately. A time that is still before the episode does not. Process-gone is unchanged.
15. A diagnosis result for a pane that moved while the pass was in flight is dropped. The old id is gone, and the new id keeps the verdict from before the pass until the next one. Deferred again: pass 15 records the id change, but the read was issued against the old pane id. After the move that id can be a bare shell, and stamping process-gone onto the new id would mark a live agent gone. The next pass reads the new id.
16. Done in pass 13. A crashed pane is its own bucket, mark (`GONE`), and footer count. herdmgr reads the process list before paint, after events, and every 15s, so a dead process is not shown as working or blocked. A failed read does not clear a crash. MCP uses the same mark and does not count a crash as unknown as well. The panel's Running tab and header use that same distinction (pass 40): a quiet worker stays running, and a crash on a finished pane is not counted as done.
17. herdmgr does not classify silence. Deferred: the table has no output clock. Timing silence from `enteredAt` would mark a busy agent quiet at the 5-minute threshold. The menu bar's heartbeat is what makes that clock real. MCP's diagnosing tools keep an episode clock and a detection baseline across calls in that process (pass 21). herdmgr's live table still does not.
18. A poll that lands before `pane.moved` still starts a new episode when the pane has no `agent_session.value`. Pass 15 carries the episode only when exactly one dropped pane and one new pane share a non-empty session value. Deferred: kind and title are shared by agents that are not the same occupant, and an empty value is what several panes look like. Selection and the detection hash still follow when the event arrives, because the new id is already a row. The duplicate blocked alert and the reset dwell for that session-less pane do not.
19. A detection read that finishes after the hash was already moved still records on the old id and does not carry a change. The next poll of the new id reports a screen that differs from the hash the move saved. Deferred: the read was addressed to the old pane id, and after the move those bytes can be the shell that replaced the agent. Parking them would clear a silence for output the agent did not produce. Pass 16 carries only a change the poll had already compared against the mover's own previous screen. A later replace of that same hop no longer installs the first look on the destination (pass 20). The read itself is unchanged. MCP's diagnosis poll is tagged with the herd serial (pass 24): once a newer read has noted its serial, the older poll drops those bytes instead of storing them. A Shepherd read is not tagged, and it is still the pane id the poll started with.
20. `agent.answer` still refuses when its pane id is gone, including when the same session is blocked on the same seq at a new id. `explain` was addressed to the old pane. After the move that id can be a shell, and the block kind that justified the keys is not a reading of the new pane. Deferred: the explain gap is short. The consecutive-answer cap follows the session (pass 18), so addressing the new id spends the same budget. Confirm-tier writes follow the session; they do not explain a screen. The refusal stays locked by `AnswerSendCheck`'s gone-pane test.
21. Close, Nudge, and Jump still address the pane id from the click. Deferred: they do not hold that id across a confirmation wait. A move during the one socket call is the write that was already queued. Close needs its own rule for whether a status change still means that occupant. Gated `agent.say` re-reads and follows a unique idle or done session (pass 22). A move after that list is the queued write in item 6. The reserve records the cooldown on the pane that was addressed and on its session.
22. The moved row's Approve button stays enabled while the original click is in flight. The click is ignored, and the footer says a response is already being sent. Deferred: disabling the button means the in-flight id set has to follow every later hop and be removed only by the task that started it. The session set already stops the second Enter.
23. A pane with no `agent_session.value` still gets a fresh answer cap and write cooldown when its id changes. Deferred: an empty value is what several panes look like, and kind plus title are not an occupant. Pass 18 follows only a non-empty session identity. The pane that was actually written stays in cooldown for 10s either way.
24. Answers recorded before a session value existed stay on the pane id. The first `recordStatusChange` that carries a session starts that session's budget at zero and clears the pane mirror on the id it observed. Deferred: treating that as the same occupant would also adopt a previous occupant's count when a new session reuses the pane at the same seq, which is the reset pass 4 exists to do. A session that is present for the whole episode is the path pass 18 covers.
25. Done in pass 20. A poll that continues several sessions replaces every detection hash in one call. A second replace of a hop that already moved does not clear the destination, and does not install a hash the old id recorded after the move. A never-polled origin still clears. Prune keeps that record while the new id is in the herd. A single move was already safe; this is the later pane in the same snapshot.
26. `fingerprintBelongs` treats a session value that continues with `|` (`abc` versus `abc|extra`) as the same occupant. `abc` versus `abcd` does not, and that case is tested. Deferred: the budget key is the identity string itself, and MCP passes the fingerprint and the identity from the same `HerdrAgentInfo`, so the two values are different keys. The prefix check only runs for fingerprints stored on that same key. The diagnosis episode clock compares the identity strings exactly, so this prefix does not join two clocks (pass 21).
27. MCP blocked and quiet durations start when that process first sees the episode. herdr has no wall clock to backdate them. A call that never got a detection read does not start the silence clock. Quiet begins only after a later read still sees that same screen, past the threshold. A gap long enough for the detection buffer to scroll can match an older hash and report quiet. Deferred: writing the clock into Shepherd's dwell file would share that file with no cross-process lock. The first call in a process reporting 0s is the observation, not a claim about the time before the server started.
28. Approve and Deny still send when the click captured no session and the pane is the same kind, still blocked, on the same seq. Pass 23 refuses that pane when a session was captured and the re-read names a different one, or names none. Deferred: an empty session value is what several panes look like, and kind is not an occupant. A restart that comes back with the same session value and the same seq is still the observation item 4 describes. There is no second fact to refuse on.
29. herdmgr's status poll does not add or remove rows. A pane `agent.list` dropped stays until `pane.updated`, `pane.closed`, `pane.exited`, or a layout refetch. Deferred: a move's new id is already in that list before `pane.moved`, and adopting the list would drop the pre-move row. The layout refetch would then remember the reset dwell. `pane.updated` still inserts an agent whose name just appeared, and drops one whose agent field is empty. The 15s process scan still marks a bare shell `GONE`.
30. A cleared rename sticks when that list also omits the metadata title, `display_agent`, and the terminal title. Deferred: a list with no display field is the same shape as one that left the title off, and pass 29 keeps the row's name in that case so a partial list cannot blank it. A list that still carries the terminal title, or a `display_agent`, shows that instead of the cleared rename. `display_agent` is not remembered on its own: the next event that leaves it off falls back to the rename, which is the field pane events do not carry. A real pane event includes `display_agent` when herdr has one.
31. Done in pass 32. herdmgr's status poll returns the rows whose status, seq, or session opened an episode, and reads the process list for those rows before it draws. A bare shell stamps `GONE` on the new episode, so a dead agent whose status string stayed `working` stays on the attention list. A same-episode poll returns nothing and is not read, so it cannot clear a crash the last scan stamped. A pane the list does not contain is not returned. An empty process read leaves the status verdict; the 15s tick still reads the whole table, which is also how a crash with no episode change is found. Done and idle are named when their episode opens, and that read returns running before any socket call. Shepherd still requests a diagnosis pass on the transition.
32. The session-less occupant fingerprint does not include `display_agent` or the pane label. Deferred: both are presentation labels. Putting either in the string would treat a metadata change as a new occupant, and fingerprints already stored on pending actions do not include them. The fingerprint's fallback is a nonempty title, then the rename, then the terminal title, then the kind (pass 31). The row's name uses the pane label between the rename and the terminal title (pass 39).
33. A title or directory that is only whitespace is still present. Deferred: trimming it would change a fingerprint or a cwd that was stored as that exact string. `""` is the cleared-field shape herdr sends. A session value that is only whitespace is still an id for the same reason (pass 35).
34. Done in pass 35. An `agent_session` with an empty value is not a session fingerprint. It uses the same fallback as a missing session, so the title still distinguishes two session-less occupants in one pane, and a list that includes the empty object agrees with one that leaves it off. A non-empty value is unchanged, including one that contains `|`. An empty `agent` on that object is not a kind; `AgentKind.resolved` keeps the detected kind on the list, the store, the move, herdmgr, and MCP. A named session agent still wins. Approve, when the click captured no session, still compares kind rather than this fingerprint (item 28).
35. Done in pass 36. The usage meter treats OpenCode as matching every provider by the kind's label. The live row is `.custom("opencode")`, and `.opencode` is the same label, including `.custom("OpenCode")`. A Claude event in a directory shared with that row stays ambiguous. A Codex event in that directory attributes to the OpenCode pane. A directory with only that pane receives the Claude event. The settings fingerprint stays `custom:opencode`. Mapping the row onto the enum case would change that key. A kind that merely contains the word, or is only whitespace, still does not match (item 33).
36. Done in pass 37. `herd.overview` and `agent.list` print `AgentID.raw` (`w1:p1`), which is the `agent_id` inspect, diagnose, tail, and the writes match. The local suffix (`p1`) is not that id, and the list no longer cuts the column at 8 characters. Read tools accept a suffix only when exactly one listed pane has it, and name both full ids otherwise. An exact id wins over a pane whose suffix is that whole string. A blank id is not a lookup. Writes still require the full id, because the answer cap and `explain` use the string the caller passed.
37. The menu-bar Approve and Deny buttons still send Enter and Esc for every block, including a probable approval and an unknown one. Deferred: those buttons do not read the matched rule. The person is looking at the prompt. MCP is the path that refuses a key the rule does not name (pass 38). Gating the buttons the same way would also refuse Enter on a prompt the panel is already showing.
38. `osc_title_blocked` is still `.approval` for every agent that shares that id, including ones whose visible cancel key is not Esc. `accept_once` is included. Deferred: the matcher sees the rule id and not the agent, and splitting one id by kind would also change Codex and Grok, which are the screens that id was mapped for. A title-only match still has no row to inspect.
39. `credential_prompt`, `confirmation_or_input_blocker`, `inline_question`, and `osc_progress_blocked` stay `.unknownBlock`. Deferred: Enter would submit a password, a shell, or a free-typed answer, or the only signal is a progress byte. A later rule id that says Enter and Esc can be named without those four.
40. A cleared pane label sticks when that snapshot also omits the metadata title, `display_agent`, the agent rename, and the terminal title. Deferred: that is the same shape as a list with no display field (item 30), and falling through to the kind would also blank a row whose title the payload left off. A snapshot that still carries any of those shows that instead of the cleared label. `herdr pane rename` itself emits no `pane.updated` on current herdr, so the label appears on the next herd read. An event that includes `label` shows it sooner. A whitespace-only label is still a label (item 33). The occupant fingerprint does not include it.
41. MCP `agent.list` with `status=working` still returns a crashed pane. Deferred: that parameter is herdr's status string, and the row's mark is already `GONE`. Dropping the row would hide a pane the caller asked for by the status herdr reported. The panel's Running scope is the product bucket, and it excludes the crash (pass 40).
42. Done in pass 41. A quote may sit between the key name and `=` or `:`, which is the JSON shape `"api_key": "…"`. A double-quoted value is the whole string, so spaces and apostrophes stay inside the redaction. A single-quoted value keeps spaces. The closing quote is left in place so a second pass still sees a placeholder boundary; `}` is not one. An unquoted value is still one token. A recognized token inside the quotes keeps its own label and counts once. A value shorter than 8 characters stays. `max_tokens` does not match.
43. A crashed pane whose status is still `working` keeps the active ring on its glyph. Deferred: the face is already `gone`, so the colour and the word are right. The ring only gets brighter. `active` is the status string.
44. Done in pass 42. `secret_key` and `secret_access_key` are assignments. `AWS_SECRET_ACCESS_KEY` is that second name with a prefix, and the prefix stays on the label. A hyphen may stand in for either underscore, which is the separator `api_key` already accepts. The captured name keeps its case. The name still has to end there: `secret_name`, `secret_keys`, `token_count`, `secretary`, and `AWS_SECRET_ACCESS_KEY_ID` stay. A 7-character value stays; an 8-character value is redacted. A recognized `xai-` value inside the quotes keeps its own label and counts once. A broad `[_-][A-Za-z0-9]+` suffix is still not used. The closing quote stays, so a second pass counts 0.
45. A backslash-escaped quote inside a double-quoted value still ends it, and a newline inside the quotes still ends it. An unquoted value of 7 characters or fewer stays. Deferred: a value pattern that accepts `\"` or a newline also accepts a quote that was the closer, and the second pass then counts the placeholder and can swallow the following brace. The 8-character floor is what keeps `token: hunter2` and a short quoted value.
46. `private_key` and `password_key` are still not redacted. Deferred: `private` is not one of the keywords, and `password` only matches when it is the end of the name. Extending `_key` to every keyword would also take `token_key`, which is a different decision from the `secret` endings pass 42 named. A PEM block is already redacted by the begin/end pattern.

## Notes

Branch `grok/ehf-loop-0926`, from `origin/main` at `34c211e`. This file was empty at the start of pass 1.
