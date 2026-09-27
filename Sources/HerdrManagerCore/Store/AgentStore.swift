import Foundation
import Observation

// MARK: - AgentStatusTransition

/// A status change `AgentStore.applyEvent` or `applyHerdSnapshot`
/// accepted, or the same status opened again because the session occupant
/// changed. Notifications and diagnosis react to this, not to the raw
/// event: the store drops stale and untracked-pane events, and those must
/// not notify either. `from` equals `to` only for that occupant change.
public struct AgentStatusTransition: Equatable, Sendable {
    public let agentId: AgentID
    /// Nil when the event or snapshot introduced a pane the store was not
    /// tracking.
    public let from: AgentStatus?
    public let to: AgentStatus
    public let stateChangeSeq: UInt64
    public let enteredAt: Date

    public init(agentId: AgentID, from: AgentStatus?, to: AgentStatus, stateChangeSeq: UInt64, enteredAt: Date) {
        self.agentId = agentId
        self.from = from
        self.to = to
        self.stateChangeSeq = stateChangeSeq
        self.enteredAt = enteredAt
    }

    /// Identifies the status episode this transition opened. `pane_updated`
    /// carries no seq, so the stored seq stays at the last `agent.list`
    /// value across several episodes; the episode start tells them apart.
    public var episodeKey: String {
        "\(agentId.raw):\(stateChangeSeq):\(enteredAt.timeIntervalSinceReferenceDate)"
    }
}

/// Epoch and request serial captured together immediately before a herd
/// snapshot is requested. `epoch` is `AgentStore.currentHerdEpoch`. `serial`
/// increases on every capture, so two reads that share an epoch — nothing
/// happened between them — still have an order. The earlier capture must not
/// paint over the later one when it returns last.
public struct HerdRequestStamp: Sendable, Equatable {
    public let epoch: UInt64
    public let serial: UInt64

    public init(epoch: UInt64, serial: UInt64) {
        self.epoch = epoch
        self.serial = serial
    }
}

// MARK: - AgentStore

@MainActor
@Observable
public final class AgentStore {
    /// Writable from this module and `@testable` tests so diagnosis and
    /// dwell restoration can update in place. Other targets still go through
    /// `applyHerdSnapshot` / `applyEvent`.
    public internal(set) var agents: [AgentID: Agent] = [:]

    /// Cached workspace/tab label maps from the last `applyHerdSnapshot`, used
    /// to resolve names for single-pane `paneUpdated` events between periodic
    /// resnapshots (those events only carry raw ids, not labels).
    private var workspaceNameCache: [String: String] = [:]
    private var tabNameCache: [String: String] = [:]

    /// One status or presence event. `seqFloor` is the lowest `agent.list`
    /// seq that can reflect the event. `epoch` is `herdEpoch` when the event
    /// landed. `continuesEpisode` is set so the next snapshot that actually
    /// applies to the pane keeps the event's `enteredAt` when the seq catches
    /// up, then clears — a later seq bump with the same status is a new dwell.
    private struct PaneBasis {
        var epoch: UInt64
        var seqFloor: UInt64
        var continuesEpisode: Bool
    }

    /// Counts status and presence events. Not UI state: snapshots capture it
    /// around a request, and tracking it would redraw the panel on every event
    /// the store is about to publish through `agents` anyway.
    @ObservationIgnored
    private var herdEpoch: UInt64 = 0

    /// Panes an event changed. A snapshot requested before `epoch` whose seq
    /// is still below `seqFloor` was answered from pre-event state and does
    /// not roll the pane back. The basis stays after that snapshot, so a
    /// second response that was already in flight — including one that
    /// returns after a newer poll — cannot roll it back either. A snapshot
    /// requested at or after `epoch` is authoritative: a herdr restart or a
    /// wrong seq-less event is corrected by the next poll that started after
    /// the event, and a seq that has caught up still applies.
    ///
    /// Callers that omit the request epoch retire `seqFloor` to 0 after one
    /// stale snapshot, which is the older one-poll behaviour.
    ///
    /// A snapshot whose request serial is older than one already adopted is
    /// dropped before any of this runs. Two reads can share an epoch, and
    /// the one captured earlier must not win just because it returned last.
    /// A later serial still applies a lower seq, so a herdr restart is not
    /// stuck behind the previous process's counter. Callers that omit the
    /// serial keep completion order.
    @ObservationIgnored
    private var paneBasis: [AgentID: PaneBasis] = [:]

    /// Last agent-session identity seen for a pane, without the pane id.
    /// `HerdrAgentInfo.occupantFingerprint` appends the pane id, so a
    /// cross-workspace move never compares equal. The session value is what
    /// stays put. Empty values are not stored: several panes can lack one,
    /// and matching them would glue unrelated rows together.
    @ObservationIgnored
    private var sessionByPane: [AgentID: String] = [:]

    /// Old id → new id for occupants the last *adopted* snapshot carried
    /// onto a pane id the store had not seen. Empty when that snapshot
    /// matched no session. A snapshot rejected for an older serial leaves
    /// this as it was; callers that check the serial do not read it. The
    /// menu bar follows selection, the silence alert, and the detection
    /// hash. Not panel state.
    @ObservationIgnored
    public private(set) var sessionMoves: [AgentID: AgentID] = [:]

    /// Monotonic id of `captureHerdRequest()` calls. Not an event count:
    /// two polls with no event between them still get distinct serials.
    @ObservationIgnored
    private var herdRequestSerial: UInt64 = 0

    /// Serial of the newest snapshot `applyHerdSnapshot` adopted. Zero until
    /// a caller passes `requestedAtSerial`. Omitted serials do not change it.
    @ObservationIgnored
    private var lastAppliedRequestSerial: UInt64 = 0

    /// Monotonic count of status and presence events applied here. Capture
    /// it immediately before requesting a herd snapshot and pass it to
    /// `applyHerdSnapshot(_:requestedAtEpoch:requestedAtSerial:)`.
    public var currentHerdEpoch: UInt64 { herdEpoch }

    /// Serial of the last snapshot `applyHerdSnapshot` adopted. Zero before
    /// any serial-tagged snapshot. The caller compares this with the serial
    /// it passed to tell an adopted snapshot from one dropped because an
    /// earlier capture returned late.
    public var lastAppliedHerdRequestSerial: UInt64 { lastAppliedRequestSerial }

    /// Capture `currentHerdEpoch` and a new request serial together, before
    /// the snapshot request is sent. The two cannot drift: nothing here awaits.
    public func captureHerdRequest() -> HerdRequestStamp {
        herdRequestSerial += 1
        return HerdRequestStamp(epoch: herdEpoch, serial: herdRequestSerial)
    }

    /// Whether a herd snapshot has been applied. The first one describes
    /// the herd as it already was, so its panes are not reported as new.
    private var hasAppliedHerd = false

    public init() {}

    // MARK: - Snapshot

    public func applySnapshot(_ snapshot: HerdrSnapshot) {
        // Build lookup maps
        let wsMap = snapshot.workspaceNameMap
        let tabMap = snapshot.tabNameMap

        var newAgents: [AgentID: Agent] = [:]

        for pane in snapshot.panes {
            // Only track panes that have an agent
            guard !pane.paneId.isEmpty else { continue }
            guard pane.agent != nil || pane.agentStatus != "unknown" else { continue }

            let agentId = AgentID(pane.paneId)
            let status = AgentStatus(rawValue: pane.agentStatus) ?? .unknown
            let wsName = wsMap[pane.workspaceId] ?? ""
            let tabName = tabMap[pane.tabId] ?? ""

            let existing = agents[agentId]
            let enteredAt: Date
            if let ex = existing, ex.status == status {
                enteredAt = ex.enteredAt
            } else {
                enteredAt = Date()
            }

            let kind: AgentKind
            if let session = pane.agentSession {
                kind = AgentKind.custom(session.agent)
            } else if let agentName = pane.agent {
                kind = AgentKind.custom(agentName)
            } else {
                kind = .custom("unknown")
            }

            let name = pane.agent ?? pane.terminalTitleStripped ?? ""

            // Preserve a diagnosed verdict across periodic snapshots so the
            // few-second reconciliation refresh doesn't flicker "silent"/"gone"
            // lines back to a generic status verdict between diagnosis passes.
            // A genuine status change still resets to the status-derived verdict.
            let verdict: Verdict
            if let ex = existing, ex.status == status {
                verdict = ex.verdict
            } else {
                verdict = Self.verdict(for: status)
            }

            let agent = Agent(
                id: agentId,
                kind: kind,
                name: name,
                displayName: name,
                status: status,
                stateChangeSeq: pane.stateChangeSeq ?? 0,
                enteredAt: enteredAt,
                lastOutputAt: existing?.lastOutputAt,
                verdict: verdict,
                workspaceName: wsName,
                tabName: tabName,
                cwd: pane.foregroundCwd ?? pane.cwd ?? ""
            )
            newAgents[agentId] = agent
        }

        // Only publish a change when the herd actually differs. The periodic
        // reconciliation snapshot (every few seconds) usually returns an
        // identical herd; rewriting the dictionary anyway would fire @Observable
        // on a timer and re-render the menu-bar panel continuously — which makes
        // a MenuBarExtra window flicker. Skipping the no-op write keeps the UI
        // calm while still picking up genuine additions/removals instantly.
        if newAgents != agents {
            agents = newAgents
        }
    }

    /// Build the herd from `agent.list` (the authoritative agent source —
    /// plain shells are never included) plus `session.snapshot`'s
    /// workspace/tab labels and focus pointers. Preferred over `applySnapshot`
    /// going forward: it has a real `stateChangeSeq` per agent, so dwell
    /// timers (`enteredAt`) reset only on a genuine state transition instead
    /// of never resetting (the old `panes[]`-based path never carried
    /// `state_change_seq`).
    ///
    /// - Returns: The status changes accepted, same shape as `applyEvent`'s.
    ///   The 3s poll can see a transition before its event arrives; the
    ///   event then finds the status unchanged and reports nothing, so a
    ///   blocked alert that listened to events alone was lost. The snapshot
    ///   that first populates the store reports none.
    ///
    /// - Parameter requestedAtEpoch: `currentHerdEpoch` from immediately
    ///   before this snapshot was requested. Responses captured earlier stay
    ///   stale for panes an event changed after the capture, however many of
    ///   them return and in whatever order. Omit to retire each guard after
    ///   a single stale snapshot.
    /// - Parameter requestedAtSerial: `HerdRequestStamp.serial` from that
    ///   same capture. Once a later capture has been adopted, this snapshot
    ///   is ignored in full — a higher seq included, which is a pre-restart
    ///   read arriving after the restarted herd. Omit to keep completion
    ///   order, where a lower seq still applies.
    @discardableResult
    public func applyHerdSnapshot(
        _ snapshot: HerdSnapshot,
        requestedAtEpoch: UInt64? = nil,
        requestedAtSerial: UInt64? = nil
    ) -> [AgentStatusTransition] {
        if let requestedAtSerial, requestedAtSerial < lastAppliedRequestSerial {
            return []
        }
        if let requestedAtSerial {
            lastAppliedRequestSerial = requestedAtSerial
        }

        var newAgents: [AgentID: Agent] = [:]
        var transitions: [AgentStatusTransition] = []
        var listed: Set<AgentID> = []
        /// Rows this snapshot was not allowed to replace. Their session
        /// stays too: remembering the rejected list's occupant would make
        /// the next read look like a new person and open the episode again.
        var heldRows: Set<AgentID> = []
        let basesAtStart = paneBasis
        // The request socket and the event socket are independent. A poll
        // captured after a cross-workspace move can be applied before
        // `pane.moved` is read. The new id is not in the store yet, so the
        // row would start over and a blocked agent would alert again. The
        // session value is the same occupant. Kind and title are not: two
        // agents share those.
        sessionMoves = [:]
        let priors = sessionContinuations(
            in: snapshot,
            requestedAtEpoch: requestedAtEpoch,
            basesAtStart: basesAtStart
        )
        var continued: Set<AgentID> = []

        for info in snapshot.agents {
            guard !info.paneId.isEmpty else { continue }
            let agentId = AgentID(info.paneId)
            listed.insert(agentId)
            // `stored` is the row already published at this id. `prior` is
            // a different pane whose session this id continues. The basis
            // guard only looks at `stored`: folding the prior in would
            // write an agent whose id is not the key, or reject the
            // continuation because the other pane's seq is ahead.
            let stored = agents[agentId]
            let prior = stored == nil ? priors[agentId] : nil
            let existing = stored ?? prior
            let priorBasis = basesAtStart[agentId]

            // Answered before an event that changed this pane: keep what
            // the event left (including its removal). The floor stays when
            // the caller threaded the request epoch, so another in-flight
            // response from before the event cannot undo it later — even
            // one that returns after a newer poll and carries a seq past
            // the event's floor but behind the seq already applied.
            if let priorBasis {
                let predates = requestedAtEpoch.map { $0 < priorBasis.epoch } ?? true
                let behindFloor = info.stateChangeSeq < priorBasis.seqFloor
                let behindStored = requestedAtEpoch != nil
                    && info.stateChangeSeq < (stored?.stateChangeSeq ?? 0)
                if predates && (behindFloor || behindStored) {
                    if let stored {
                        newAgents[agentId] = stored
                    }
                    heldRows.insert(agentId)
                    if requestedAtEpoch == nil {
                        paneBasis[agentId] = PaneBasis(
                            epoch: priorBasis.epoch,
                            seqFloor: 0,
                            continuesEpisode: priorBasis.continuesEpisode
                        )
                    }
                    continue
                }
            }

            // An entry with no agent is a plain shell, not an agent — never
            // insert it. (agentList()/parseAgentList already filters these
            // out, but a defensive check here keeps this function correct
            // even if called with a hand-built HerdSnapshot.)
            guard let agentKind = info.agent, !agentKind.isEmpty else {
                consumeEpisodeContinuation(agentId)
                continue
            }

            let status = AgentStatus(rawValue: info.agentStatus) ?? .unknown
            let wsName = snapshot.workspaceNames[info.workspaceId] ?? info.workspaceId
            let tabName = snapshot.tabNames[info.tabId] ?? info.tabId

            // stateChangeSeq is the authoritative "did this agent's state
            // genuinely change" signal. Also reset when the status string
            // moved but seq did not (seq of 0 on a pane_updated-shaped
            // snapshot, or a lagging seq): otherwise dwell and verdict
            // stick to the previous episode. A snapshot catching up with an
            // event's status continues the episode that event opened; once
            // that snapshot has landed, a later seq bump is a new dwell.
            let seqUnchanged = existing?.stateChangeSeq == info.stateChangeSeq
            let statusUnchanged = existing?.status == status
            // A different session in this same pane is a different occupant,
            // even at the same status and seq. A missing session is not:
            // the field arrives late, and a seq-less event leaves it off.
            // The prior row is a continuation of one session, so it does
            // not count as the occupant this id already had.
            let occupantReplaced = stored != nil && SessionIdentity.replaced(
                stored: sessionByPane[agentId],
                incoming: info.sessionIdentity
            )
            // `continuesEpisode` belongs to an event on *this* id. A row
            // carried from another pane already has its seq on this poll;
            // borrowing the new id's flag would keep the mover's dwell
            // across a seq change that belongs to someone who left.
            let sameEpisode = !occupantReplaced && existing != nil && statusUnchanged
                && (seqUnchanged || (prior == nil && priorBasis?.continuesEpisode == true))
            let enteredAt = sameEpisode ? existing!.enteredAt : Date()

            let kind: AgentKind
            if let session = info.agentSession {
                kind = .custom(session.agent)
            } else {
                kind = .custom(agentKind)
            }

            let name = info.title ?? info.terminalTitleStripped ?? agentKind

            let verdict: Verdict
            if sameEpisode {
                verdict = existing!.verdict
            } else {
                verdict = Self.verdict(for: status)
            }

            let agent = Agent(
                id: agentId,
                kind: kind,
                name: name,
                displayName: name,
                status: status,
                stateChangeSeq: info.stateChangeSeq,
                enteredAt: enteredAt,
                lastOutputAt: existing?.lastOutputAt,
                verdict: verdict,
                workspaceName: wsName,
                tabName: tabName,
                cwd: info.foregroundCwd ?? info.cwd ?? ""
            )
            newAgents[agentId] = agent
            consumeEpisodeContinuation(agentId)
            if let prior {
                // The old id is the one a list from before this poll still
                // names. Tombstone it the way a move event does. Do not mark
                // the new id as continuing: this poll already has the seq,
                // and a later bump is a new dwell.
                sessionMoves[prior.id] = agentId
                noteReplacedPane(prior.id, seq: info.stateChangeSeq == 0 ? prior.stateChangeSeq : info.stateChangeSeq)
                continued.insert(prior.id)
            }
            if existing != nil || hasAppliedHerd,
               let transition = Self.transition(
                   from: existing?.status,
                   to: agent,
                   occupantChanged: occupantReplaced
               ) {
                transitions.append(transition)
            }
        }

        // The new id was not published, because a stale basis rejected it.
        // Keep the occupant on the old id. Dropping it would remove the
        // only row.
        for prior in priors.values where !continued.contains(prior.id) && newAgents[prior.id] == nil {
            newAgents[prior.id] = prior
        }

        // A pane an event added or removed that this snapshot does not list.
        // A request from before the event keeps the event's row (or its
        // absence). A request from after the event is the herd as it is.
        for (agentId, priorBasis) in basesAtStart where priorBasis.seqFloor > 0 && !listed.contains(agentId) {
            let predates = requestedAtEpoch.map { $0 < priorBasis.epoch } ?? true
            if predates {
                if let existing = agents[agentId] {
                    newAgents[agentId] = existing
                }
                heldRows.insert(agentId)
                if requestedAtEpoch == nil {
                    paneBasis[agentId] = PaneBasis(
                        epoch: priorBasis.epoch,
                        seqFloor: 0,
                        continuesEpisode: priorBasis.continuesEpisode
                    )
                }
            } else {
                consumeEpisodeContinuation(agentId)
            }
        }
        hasAppliedHerd = true

        // Cache labels so single-pane `paneUpdated` events (which only carry
        // raw workspace/tab ids) can still resolve human-readable names
        // between periodic resyncs.
        workspaceNameCache = snapshot.workspaceNames
        tabNameCache = snapshot.tabNames

        if newAgents != agents {
            agents = newAgents
        }
        rememberSessions(from: snapshot, keptIds: newAgents.keys, holding: heldRows)
        return transitions
    }

    /// Panes this snapshot introduced whose session value belongs to exactly
    /// one pane it dropped. Ambiguous values match nothing: two rows with
    /// the same value must not trade dwell. A pane an earlier event is still
    /// holding against this snapshot is not a source — the row stays, and
    /// the new id is someone else.
    private func sessionContinuations(
        in snapshot: HerdSnapshot,
        requestedAtEpoch: UInt64?,
        basesAtStart: [AgentID: PaneBasis]
    ) -> [AgentID: Agent] {
        var listed: Set<AgentID> = []
        var incoming: [AgentID: String] = [:]
        for info in snapshot.agents {
            guard !info.paneId.isEmpty else { continue }
            guard let agent = info.agent, !agent.isEmpty else { continue }
            let id = AgentID(info.paneId)
            listed.insert(id)
            if let session = info.sessionIdentity {
                incoming[id] = session
            }
        }

        func keptDespiteAbsence(_ id: AgentID) -> Bool {
            guard let basis = basesAtStart[id], basis.seqFloor > 0 else { return false }
            let predates = requestedAtEpoch.map { $0 < basis.epoch } ?? true
            return predates
        }

        var removedBySession: [String: AgentID] = [:]
        var removedAmbiguous: Set<String> = []
        for id in agents.keys where !listed.contains(id) && !keptDespiteAbsence(id) {
            guard let session = sessionByPane[id] else { continue }
            if removedBySession[session] != nil || removedAmbiguous.contains(session) {
                removedAmbiguous.insert(session)
                removedBySession.removeValue(forKey: session)
            } else {
                removedBySession[session] = id
            }
        }

        var addedBySession: [String: AgentID] = [:]
        var addedAmbiguous: Set<String> = []
        for (id, session) in incoming where agents[id] == nil {
            if addedBySession[session] != nil || addedAmbiguous.contains(session) {
                addedAmbiguous.insert(session)
                addedBySession.removeValue(forKey: session)
            } else {
                addedBySession[session] = id
            }
        }

        var priors: [AgentID: Agent] = [:]
        for (session, newId) in addedBySession {
            guard !addedAmbiguous.contains(session), !removedAmbiguous.contains(session),
                  let oldId = removedBySession[session],
                  let agent = agents[oldId] else { continue }
            priors[newId] = agent
        }
        return priors
    }

    /// Remember who is in each kept pane.
    ///
    /// A payload that names a session replaces the one stored for that
    /// pane, except while `holding` it. That list was captured before an
    /// event this snapshot was not allowed to paint over, and storing its
    /// occupant would make the next read look like another replacement.
    /// A list that leaves `agent_session` off keeps the identity already
    /// stored. The field is absent on a seq-less update and is not on
    /// every `agent.list`. Forgetting it made the next session look like
    /// the first one this pane had ever named, so the dwell, the silence,
    /// and the crash stayed with the new person. A pane that left the
    /// herd is not in `keptIds`, and its identity goes with it.
    private func rememberSessions(
        from snapshot: HerdSnapshot,
        keptIds: some Sequence<AgentID>,
        holding: Set<AgentID> = []
    ) {
        var incoming: [AgentID: String] = [:]
        for info in snapshot.agents {
            guard !info.paneId.isEmpty, let session = info.sessionIdentity else { continue }
            incoming[AgentID(info.paneId)] = session
        }
        var next: [AgentID: String] = [:]
        for id in keptIds {
            if holding.contains(id), let kept = sessionByPane[id] {
                next[id] = kept
            } else if let session = incoming[id] {
                next[id] = session
            } else if let kept = sessionByPane[id] {
                next[id] = kept
            }
        }
        sessionByPane = next
    }

    /// Session identity last stored for `id`, without the pane id.
    ///
    /// The menu bar copies this before awaiting the herd re-read that
    /// Approve and Deny send against. A move that lands during that read
    /// takes the identity off this id; the copy is what still names the
    /// occupant on the new one.
    public func sessionIdentity(for id: AgentID) -> String? {
        sessionByPane[id]
    }

    /// A list captured before this poll still names `paneId`. Keep it from
    /// being inserted next to the row the poll already continued. The new
    /// id is not marked as an open episode: the poll carried the real seq.
    private func noteReplacedPane(_ paneId: AgentID, seq: UInt64) {
        herdEpoch += 1
        paneBasis[paneId] = PaneBasis(
            epoch: herdEpoch,
            seqFloor: Self.seq(after: seq),
            continuesEpisode: false
        )
    }

    /// The session moves with the row. A move payload often has no
    /// `agent_session`; the identity the last list stored is the one a
    /// later poll has to match. A payload that does name a session wins.
    private func carrySession(of info: HerdrAgentInfo, from previousId: AgentID, to newId: AgentID) {
        if let incoming = info.sessionIdentity {
            if previousId != newId {
                sessionByPane.removeValue(forKey: previousId)
            }
            sessionByPane[newId] = incoming
        } else if previousId != newId, let carried = sessionByPane.removeValue(forKey: previousId) {
            sessionByPane[newId] = carried
        }
    }

    // MARK: - Events

    /// Apply one subscription event.
    /// - Returns: The status change the store accepted, or nil when the event
    ///   carried no status, was stale, targeted an untracked pane, or left
    ///   the status unchanged.
    @discardableResult
    public func applyEvent(_ event: HerdrEvent) -> AgentStatusTransition? {
        switch event {
        case .agentStatusChanged(let paneId, let agentStatus, let seq):
            let agentId = AgentID(paneId)
            guard var agent = agents[agentId] else { return nil }

            // Sequence guard: only apply if new seq >= current
            if let newSeq = seq, newSeq < agent.stateChangeSeq {
                return nil
            }

            let previousStatus = agent.status
            let newStatus = AgentStatus(rawValue: agentStatus) ?? .unknown
            if newStatus != agent.status {
                agent.enteredAt = Date()
                noteEventChange(for: agentId, seqFloor: seq ?? Self.seq(after: agent.stateChangeSeq))
            }
            agent.status = newStatus
            if let seq { agent.stateChangeSeq = seq }
            agent.verdict = Self.verdict(for: newStatus)
            agents[agentId] = agent
            return Self.transition(from: previousStatus, to: agent)

        case .paneCreated:
            // Every new pane starts as a plain shell. A placeholder row for
            // it was an `.unknown` agent: counted, listed, and diagnosed, so
            // a pass in the seconds before the next resync could stamp the
            // bare shell process-gone and flash a red "gone". The agent
            // arrives with the `pane_updated` that first names its kind.
            break

        case .paneClosed(let paneId):
            removeAfterEvent(AgentID(paneId))

        case .paneMoved(let previousPaneId, let info, let createdWorkspaceLabel, let createdTabLabel):
            return applyPaneMove(
                previousPaneId: previousPaneId,
                info: info,
                createdWorkspaceLabel: createdWorkspaceLabel,
                createdTabLabel: createdTabLabel
            )

        case .paneUpdated(let info):
            guard !info.paneId.isEmpty else { return nil }
            let agentId = AgentID(info.paneId)
            let existing = agents[agentId]

            // A real seq behind the stored one is an older state than the
            // store already holds — an event that was queued while a newer
            // `agent.list` resync or status event landed. Applying it would
            // move the status backward (blocked -> working) and drag the
            // stored seq down with it.
            if info.stateChangeSeq != 0, let existing, info.stateChangeSeq < existing.stateChangeSeq {
                return nil
            }

            let seqIsMeaningful = info.stateChangeSeq != 0

            guard let agentKind = info.agent, !agentKind.isEmpty else {
                // The pane no longer runs an agent (dropped back to a plain
                // shell) — it is not an agent anymore, so drop it too.
                removeAfterEvent(agentId, seq: seqIsMeaningful ? info.stateChangeSeq : nil)
                return nil
            }

            let status = AgentStatus(rawValue: info.agentStatus) ?? .unknown

            // `pane_updated` events don't carry `state_change_seq` (only
            // `agent.list` does — see applyHerdSnapshot), so a real seq of 0
            // means "not provided here"; fall back to comparing agent_status
            // so a genuine transition still resets `enteredAt` in between
            // periodic `agent.list` resyncs. A session that arrives on the
            // event and differs from the one the row has is a new occupant
            // even when the status string did not move.
            let occupantReplaced = existing != nil && SessionIdentity.replaced(
                stored: sessionByPane[agentId],
                incoming: info.sessionIdentity
            )
            let seqChanged = seqIsMeaningful && existing?.stateChangeSeq != info.stateChangeSeq
            let statusChanged = existing?.status != status
            let isNewState = existing == nil || seqChanged || statusChanged || occupantReplaced

            let enteredAt = isNewState ? Date() : existing!.enteredAt
            let verdict = isNewState ? Self.verdict(for: status) : existing!.verdict
            if statusChanged || occupantReplaced {
                noteEventChange(
                    for: agentId,
                    seqFloor: seqIsMeaningful
                        ? info.stateChangeSeq
                        : Self.seq(after: existing?.stateChangeSeq ?? 0)
                )
            }

            let kind: AgentKind
            if let session = info.agentSession {
                kind = .custom(session.agent)
            } else {
                kind = .custom(agentKind)
            }
            let name = info.title ?? info.terminalTitleStripped ?? agentKind
            let wsName = workspaceNameCache[info.workspaceId] ?? existing?.workspaceName ?? info.workspaceId
            let tabName = tabNameCache[info.tabId] ?? existing?.tabName ?? info.tabId
            // A real (non-zero) seq replaces the stored one; otherwise keep
            // whatever `agent.list` last established so the next resync's
            // seq-equality check isn't corrupted by this event's absence of
            // a real sequence number.
            let stateChangeSeq = seqIsMeaningful ? info.stateChangeSeq : (existing?.stateChangeSeq ?? 0)

            let updated = Agent(
                id: agentId,
                kind: kind,
                name: name,
                displayName: name,
                status: status,
                stateChangeSeq: stateChangeSeq,
                enteredAt: enteredAt,
                lastOutputAt: existing?.lastOutputAt,
                verdict: verdict,
                workspaceName: wsName,
                tabName: tabName,
                cwd: info.foregroundCwd ?? info.cwd ?? existing?.cwd ?? ""
            )
            agents[agentId] = updated
            carrySession(of: info, from: agentId, to: agentId)
            return Self.transition(
                from: existing?.status,
                to: updated,
                occupantChanged: occupantReplaced
            )

        case .paneFocused:
            // Focus changes don't affect dwell/verdict state, and `Agent`
            // doesn't currently track a `focused` flag — nothing to update.
            break

        case .paneExited(let paneId):
            removeAfterEvent(AgentID(paneId))

        case .workspacesChanged:
            // Labels changed; the caller is responsible for triggering a
            // fresh `herdSnapshot()` to resync workspace/tab names — this
            // store has no adapter reference to do that itself.
            break

        case .connected, .disconnected, .ignored:
            break
        }
        return nil
    }

    /// Re-key a moved pane onto the id herdr now publishes.
    ///
    /// A cross-workspace move assigns a new public pane id and does not
    /// emit close or create. Treating the event as an update of the new id
    /// left the row on the old one, so the next poll inserted a second
    /// agent and alerted again for a block that had only changed rooms.
    /// The episode (dwell, verdict, last output) stays. A snapshot captured
    /// before the move cannot put the old id back or drop the new one.
    private func applyPaneMove(
        previousPaneId: String,
        info: HerdrAgentInfo,
        createdWorkspaceLabel: String?,
        createdTabLabel: String?
    ) -> AgentStatusTransition? {
        guard !info.paneId.isEmpty else { return nil }

        let previousId = AgentID(previousPaneId.isEmpty ? info.paneId : previousPaneId)
        let newId = AgentID(info.paneId)
        let existing = agents[previousId] ?? (previousId == newId ? nil : agents[newId])

        // `PaneInfo` has no `state_change_seq`, so a real `pane_moved`
        // parses as 0. On the protocol-17 baseline herdr also replays the
        // retained event buffer at subscribe. That replay must not insert a
        // pane the snapshot does not have, or replace the episode the
        // snapshot just established. A live move still re-keys the row we
        // are tracking. Status changes keep arriving as `pane_updated`.
        if info.stateChangeSeq == 0 && existing == nil {
            return nil
        }

        // A container this move created. Do not replace a name the last
        // snapshot already stored: a replayed move carries the label from
        // back then, and a rename since then lives in the cache.
        if let createdWorkspaceLabel, !info.workspaceId.isEmpty,
           workspaceNameCache[info.workspaceId] == nil {
            workspaceNameCache[info.workspaceId] = createdWorkspaceLabel
        }
        if let createdTabLabel, !info.tabId.isEmpty,
           tabNameCache[info.tabId] == nil {
            tabNameCache[info.tabId] = createdTabLabel
        }

        guard let agentKind = info.agent, !agentKind.isEmpty else {
            if previousId != newId {
                removeAfterEvent(previousId)
            }
            removeAfterEvent(newId)
            return nil
        }

        // The moved pane carries its current seq. A seq behind the one
        // `agent.list` already applied is an older status riding along
        // with the location change; keep the newer status. A higher seq
        // with the same status is still this episode — the move itself
        // is not a new dwell. A seq of 0 is "not on this event": keep the
        // stored episode and only change where the row lives.
        let seqIsMeaningful = info.stateChangeSeq != 0
        let seqBehind = seqIsMeaningful && existing != nil && info.stateChangeSeq < existing!.stateChangeSeq
        let status: AgentStatus
        if !seqIsMeaningful, let existing {
            status = existing.status
        } else if seqBehind {
            status = existing!.status
        } else {
            status = AgentStatus(rawValue: info.agentStatus) ?? .unknown
        }
        // The poll may already have published the new id and dropped the
        // session off the old one. Either id can still be holding it.
        let storedSession = sessionByPane[previousId]
            ?? (previousId == newId ? nil : sessionByPane[newId])
        let occupantReplaced = existing != nil && SessionIdentity.replaced(
            stored: storedSession,
            incoming: info.sessionIdentity
        )
        let statusChanged = existing?.status != status
        let opensEpisode = existing == nil || statusChanged || occupantReplaced
        let enteredAt = opensEpisode ? Date() : existing!.enteredAt
        let verdict = opensEpisode ? Self.verdict(for: status) : existing!.verdict
        let stateChangeSeq: UInt64
        if !seqIsMeaningful, let existing {
            stateChangeSeq = existing.stateChangeSeq
        } else if seqBehind {
            stateChangeSeq = existing!.stateChangeSeq
        } else if seqIsMeaningful {
            stateChangeSeq = info.stateChangeSeq
        } else {
            stateChangeSeq = existing?.stateChangeSeq ?? 0
        }

        let kind: AgentKind
        if let session = info.agentSession {
            kind = .custom(session.agent)
        } else {
            kind = .custom(agentKind)
        }
        let name = info.title ?? info.terminalTitleStripped ?? existing?.name ?? agentKind
        let wsName = info.workspaceId.isEmpty
            ? (existing?.workspaceName ?? "")
            : (workspaceNameCache[info.workspaceId] ?? info.workspaceId)
        let tabName = info.tabId.isEmpty
            ? (existing?.tabName ?? "")
            : (tabNameCache[info.tabId] ?? info.tabId)
        let updated = Agent(
            id: newId,
            kind: kind,
            name: name,
            displayName: name,
            status: status,
            stateChangeSeq: stateChangeSeq,
            enteredAt: enteredAt,
            lastOutputAt: existing?.lastOutputAt,
            verdict: verdict,
            workspaceName: wsName,
            tabName: tabName,
            cwd: info.foregroundCwd ?? info.cwd ?? existing?.cwd ?? ""
        )

        let carriedEpisode: Bool
        if let previous = paneBasis[previousId]?.continuesEpisode {
            carriedEpisode = previous
        } else if previousId != newId, let arrived = paneBasis[newId]?.continuesEpisode {
            carriedEpisode = arrived
        } else {
            carriedEpisode = false
        }
        var next = agents
        if previousId != newId {
            next.removeValue(forKey: previousId)
        }
        next[newId] = updated
        if next != agents {
            agents = next
        }
        carrySession(of: info, from: previousId, to: newId)
        notePaneMove(
            from: previousId,
            to: newId,
            seqFloor: Self.seq(after: stateChangeSeq),
            continuesEpisode: statusChanged || occupantReplaced || carriedEpisode
        )
        return Self.transition(
            from: existing?.status,
            to: updated,
            occupantChanged: occupantReplaced
        )
    }

    /// Remember a move. The previous id is a tombstone so a list captured
    /// before the move cannot insert it again. The new id is kept when that
    /// list does not contain it yet. Both share one epoch.
    private func notePaneMove(
        from previousId: AgentID,
        to newId: AgentID,
        seqFloor: UInt64,
        continuesEpisode: Bool
    ) {
        herdEpoch += 1
        if previousId != newId {
            paneBasis[previousId] = PaneBasis(
                epoch: herdEpoch,
                seqFloor: seqFloor,
                continuesEpisode: false
            )
        }
        paneBasis[newId] = PaneBasis(
            epoch: herdEpoch,
            seqFloor: seqFloor,
            continuesEpisode: continuesEpisode
        )
    }

    /// Drop a pane an event removed, and keep a snapshot answered before
    /// that event from adding it back.
    private func removeAfterEvent(_ agentId: AgentID, seq: UInt64? = nil) {
        guard let removed = agents.removeValue(forKey: agentId) else { return }
        sessionByPane.removeValue(forKey: agentId)
        noteEventChange(for: agentId, seqFloor: seq ?? Self.seq(after: removed.stateChangeSeq))
    }

    /// Record that a status or presence event changed this pane, and that a
    /// snapshot requested earlier must not paint over it.
    private func noteEventChange(for agentId: AgentID, seqFloor: UInt64) {
        herdEpoch += 1
        paneBasis[agentId] = PaneBasis(epoch: herdEpoch, seqFloor: seqFloor, continuesEpisode: true)
    }

    /// The event's dwell has been adopted or replaced by a snapshot that
    /// applied. The seq floor stays, so a response requested before the
    /// event is still rejected if it arrives later.
    private func consumeEpisodeContinuation(_ agentId: AgentID) {
        guard var basis = paneBasis[agentId], basis.continuesEpisode else { return }
        basis.continuesEpisode = false
        paneBasis[agentId] = basis
    }

    /// The lowest seq herdr can report once it has moved past `seq`.
    private static func seq(after seq: UInt64) -> UInt64 {
        seq == .max ? seq : seq + 1
    }

    private static func transition(
        from previous: AgentStatus?,
        to agent: Agent,
        occupantChanged: Bool = false
    ) -> AgentStatusTransition? {
        guard occupantChanged || previous != agent.status else { return nil }
        return AgentStatusTransition(
            agentId: agent.id,
            from: previous,
            to: agent.status,
            stateChangeSeq: agent.stateChangeSeq,
            enteredAt: agent.enteredAt
        )
    }

    /// Apply persisted dwell timestamps back onto the live agents after a
    /// relaunch so displayed and diagnosed dwell time is not reset. Only
    /// entries the DwellTracker validated (occupant fingerprint + seq match)
    /// should be passed in. Restored timestamps are applied only when earlier
    /// than the current value (dwell is never moved forward).
    public func applyRestoredDwell(_ restored: [AgentID: DwellEntry]) {
        for (agentId, entry) in restored {
            guard var agent = agents[agentId] else { continue }
            if entry.enteredAt < agent.enteredAt {
                agent.enteredAt = entry.enteredAt
            }
            if let restoredOutput = entry.lastOutputAt,
               restoredOutput > (agent.lastOutputAt ?? .distantPast) {
                agent.lastOutputAt = restoredOutput
            }
            agents[agentId] = agent
        }
    }

    // MARK: - Computed Properties

    public var attentionAgents: [Agent] {
        agents.values
            .filter { AttentionTriage.attentionWorthy($0) }
            .sorted(by: AttentionTriage.ranksBefore)
    }

    public var blockedCount: Int {
        agents.values.filter { AttentionTriage.isActionablyBlocked($0) }.count
    }

    public var silentCount: Int {
        agents.values.filter { AttentionTriage.isActionablySilent($0) }.count
    }

    public var doneCount: Int {
        agents.values.filter { $0.status == .done }.count
    }

    // MARK: - Diagnosis

    /// Diagnose all non-idle agents and update their verdicts.
    /// - Parameters:
    ///   - adapter: The HerdrAdapter to use for herdr API calls.
    ///   - diagnoser: The Diagnoser to classify each agent.
    ///   - settings: Optional SettingsStore for per-agent silent-threshold
    ///     overrides. When nil, each agent falls back to the kind-based
    ///     default (source-compatible with the previous signature).
    ///   - first: Agents to diagnose before the rest, typically the ones
    ///     whose transition asked for this pass, so their verdict does not
    ///     wait on the rest of the herd.
    public func diagnoseAll(
        adapter: HerdrAdapter,
        diagnoser: Diagnoser,
        settings: SettingsStore? = nil,
        first: Set<AgentID> = []
    ) async {
        let nonIdle = agents.values
            .filter { $0.status != .idle }
            .sorted { first.contains($0.id) && !first.contains($1.id) }
        // Captured with the copies above, before any await. A session that
        // arrives while explain is in flight is still this occupant. A
        // different one is not, and the verdict was read from the pane the
        // old session occupied.
        var sessionAtStart: [AgentID: String] = [:]
        for agent in nonIdle {
            if let session = sessionByPane[agent.id] {
                sessionAtStart[agent.id] = session
            }
        }

        // Snapshot per-agent thresholds off the actor before the loop so we
        // don't hop into SettingsStore on every iteration.
        let thresholds: [String: TimeInterval]?
        if let settings {
            var map: [String: TimeInterval] = [:]
            for agent in nonIdle {
                // SettingsStore keys overrides by pane-id (the herdr session
                // identity). `agent.id.raw` is the full "wX:pY" form; the
                // pane component is what the UI persists.
                // Look up by occupant identity first (follows the agent across
                // panes), falling back to the pane-id key, then the default.
                let minutes = await settings.threshold(
                    for: agent.id.raw,
                    occupant: DwellTracker.fingerprint(for: agent)
                )
                map[agent.id.raw] = TimeInterval(minutes) * 60.0
            }
            thresholds = map
        } else {
            thresholds = nil
        }

        for agent in nonIdle {
            let override = thresholds?[agent.id.raw]
            let verdict = await diagnoser.diagnose(
                agent: agent,
                adapter: adapter,
                silentThreshold: override
            )
            // Update on MainActor (we're already @MainActor)
            // Drop the verdict if the pane changed while diagnose was in
            // flight. Stamping silent onto a pane that finished or blocked
            // is how a stale "quiet" reason survived on done/blocked rows.
            // The silence itself was measured on the copy taken before this
            // pass's other reads. Heartbeat can move lastOutputAt during
            // those reads; re-measure the row as it is now so that output
            // does not get a quiet alert.
            if var current = agents[agent.id],
               current.status == agent.status,
               current.stateChangeSeq == agent.stateChangeSeq,
               !SessionIdentity.replaced(
                   stored: sessionAtStart[agent.id],
                   incoming: sessionByPane[agent.id]
               ) {
                current.verdict = Self.silenceOnCurrentClock(
                    verdict,
                    agent: current,
                    silentThreshold: override
                )
                agents[agent.id] = current
            }
        }
    }

    /// Record output the heartbeat just observed.
    ///
    /// A newer time moves `lastOutputAt`. When that also moves the silence
    /// clock, the quiet on the row has ended and the badge comes down now,
    /// instead of waiting for the next diagnosis pass. The pass is what
    /// decides the next quiet. A time that is not newer does not move the
    /// clock backward. A time that is still before the episode does not end
    /// a silence measured from `enteredAt`.
    ///
    /// The menu bar also calls this with the time a move carried. The poll
    /// recorded that change under the previous pane id, which is gone.
    public func applyObservedOutput(_ updates: [AgentID: Date]) {
        for (agentId, date) in updates {
            guard var agent = agents[agentId] else { continue }
            if let existing = agent.lastOutputAt, date <= existing { continue }
            agent.lastOutputAt = date
            if case .silent(let since, _) = agent.verdict,
               Diagnoser.silentClockStart(for: agent) != since {
                agent.verdict = .healthy
            }
            agents[agentId] = agent
        }
    }

    /// Start heartbeat polling. Returns a Task that polls every 10 seconds.
    /// The caller is responsible for cancelling the task.
    public func startHeartbeatPolling(adapter: HerdrAdapter, poller: HeartbeatPoller) -> Task<Void, Never> {
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000) // 10 seconds
                guard let self else { return }

                let workingAgents = self.agents.values.filter { $0.status == .working }
                await poller.prune(keeping: Set(self.agents.keys))
                let updates = await poller.poll(agents: workingAgents, adapter: adapter)

                // Apply lastOutputAt updates on MainActor. New output ends
                // a silence the row is already showing.
                await MainActor.run {
                    self.applyObservedOutput(updates)
                }
            }
        }
    }

    // MARK: - Helpers

    /// A `.silent` verdict was computed from the agent copy this pass
    /// started with. `agent` is the row now. Output since that copy leaves
    /// a working pane healthy; a row that is still quiet keeps this pass's
    /// CPU reading and the current clock. Any other verdict does not use
    /// the output clock.
    private static func silenceOnCurrentClock(
        _ verdict: Verdict,
        agent: Agent,
        silentThreshold: TimeInterval?
    ) -> Verdict {
        guard case .silent(_, let cpu) = verdict else { return verdict }
        let start = Diagnoser.silentClockStart(for: agent)
        let threshold = silentThreshold ?? Diagnoser.silentThreshold(for: agent.kind)
        guard Date().timeIntervalSince(start) > threshold else { return .healthy }
        return .silent(since: start, cpu: cpu)
    }

    private static func verdict(for status: AgentStatus) -> Verdict {
        switch status {
        case .blocked:
            return .awaitingInput(BlockClassification(
                kind: .unknownBlock, since: Date(), summary: "blocked"
            ))
        case .idle, .working: return .healthy
        case .done: return .healthy
        case .unknown: return .unclassifiable(reason: "unknown status")
        }
    }
}
