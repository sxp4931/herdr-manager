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

## Backlog / ideas

1. A seq-less `pane_updated` that arrives after a poll already applied a newer status still flips the pane. The event carries no seq, so it cannot be told apart from a genuine second prompt. Deferred again: any rule that drops a seq-less status change also drops the live update the subscription exists to deliver. A non-zero seq is already ignored when it is behind the stored one.
2. Dwell restore still matches a reused pane on kind + non-zero seq + status. `agent_session.value` is parsed onto `HerdrAgentInfo` and not kept on `Agent`. Putting it in the occupant fingerprint would also change Settings override keys (`DwellTracker.fingerprint` and `AppModel.fingerprintForAgent` must stay identical). Deferred: needs a second identity stored on `Agent` and in the dwell file, with old files still matching, and it is a separate change from the answer-send check. The MCP write path compares session value; the panel Approve/Deny check and the dwell file still do not.
3. `paneBasis` keeps a tombstone for a pane a status, presence, or move event touched, including the previous id after a cross-workspace move, so a late pre-event list cannot resurrect it. Pane ids are not reused; the map grows with ids seen this launch. Deferred: one or two structs per moved pane per launch is not worth a pruning rule that might drop a basis an in-flight read still needs.
4. A herdr restart that reuses a pane id and comes back at the same `state_change_seq` with the same occupant fingerprint does not reset the 3-answer cap. Deferred: that read looks exactly like a second observation of the episode the cap is counting. Resetting on an equal seq would let a stale read clear the cap, which the policy test forbids. A lower seq, or the same seq with a new session value, does reset.
5. Done in pass 7. A connect failure, a refresh that fails, and a dropped subscription clear the protocol under the enqueue epoch. A herd read that already started cannot record over that clear. A read that starts afterwards still can. `setLatestProtocol` with a nil epoch still bypasses that floor; no request path calls it that way.
6. Gated `agent.say` reads the pane, then awaits `checkWritesEnabled`, then prompts, with no second read. A status change in that gap still receives the text. Deferred: it is a message, not a key bound to one prompt, and the confirm-tier tools already revalidate immediately before their send.
7. `HerdrAgentInfo.==` does not compare `agentSession` (`AgentSession` is not `Equatable`). `AnswerSendCheck` uses the fingerprint, not `==`. The store, the snapshot merge, and the write path do not branch on `HerdrAgentInfo` equality, so the missing field does not change behavior today. Deferred: making `AgentSession` equatable is safe, and still has no caller.
8. herdmgr resets dwell when a move also emits `workspace.created`, `tab.created`, `workspace.closed`, or `tab.closed`. herdr emits those before `pane.moved`, and herdmgr refetches on `workspacesChanged` before it reads the move, so the new id is adopted as a new row. Deferred: keeping the pre-resync rows until the move arrives means recognizing the burst, and holding that list across a later unrelated event would rebuild the table from stale rows. Shepherd does not refetch on those events, so pass 6's re-key runs first there.
9. A seq-less `pane_moved` does not adopt a status that appears only on that payload. Deferred: `PaneInfo` has no seq, so a live status and a replayed one are the same bytes. Applying the payload status is what made a protocol-17 buffer replay reopen a blocked episode. `pane.updated` and Shepherd's poll still carry status. herdmgr misses a status change that arrived only inside the move until the next `pane_updated`.
10. A seq-less `pane_moved` with no agent still drops a row whose id matches. A replayed same-id move-to-shell can remove an agent that started in that pane later. Deferred: a live move to a shell has the same shape, and leaving the row would stick in herdmgr. Shepherd's next poll inserts the agent again.

## Notes

Branch `grok/ehf-loop-0926`, from `origin/main` at `34c211e`. This file was empty at the start of pass 1.
