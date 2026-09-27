import Foundation

// MARK: - DiagnosisEpisodeLedger

/// When this process first saw each status episode.
///
/// herdr puts no wall clock on an agent. A caller that builds a fresh
/// `Agent` on every read stamps `enteredAt` at that read, so a blocked
/// agent looks newly blocked and a working agent can never go quiet.
/// The ledger keeps the first observation of a status and
/// `state_change_seq`, and moves it when a cross-workspace move is the
/// only pane that left and the only pane that arrived with that session.
///
/// An empty session value is not an identity. Two panes sharing one value
/// do not trade clocks. A session string that merely continues another
/// (`abc` and `abc|extra`) is a different occupant.
public struct DiagnosisEpisodeLedger: Sendable {
    /// Pane ids whose episode continued onto a new id.
    ///
    /// The detection hash is stored by pane id. A caller that compares
    /// screens retargets these before the next read, or the new id is a
    /// first look and the screen the agent landed on never counts as output.
    /// A move that also changes status or seq is not included: that is a
    /// new episode, and the previous screen is not its baseline.
    public struct Observation: Sendable, Equatable {
        public var enteredAt: [AgentID: Date]
        public var moves: [AgentID: AgentID]

        public init(enteredAt: [AgentID: Date], moves: [AgentID: AgentID]) {
            self.enteredAt = enteredAt
            self.moves = moves
        }
    }

    private struct Episode: Sendable {
        var status: AgentStatus
        var seq: UInt64
        var enteredAt: Date
        var session: String?
    }

    private var episodes: [AgentID: Episode] = [:]

    public init() {}

    /// Clocks for the agents in `infos`, and the pane ids a session just
    /// changed. Shells and empty pane ids are ignored. An agent missing
    /// from `infos` is forgotten, so the next time it appears is a new episode.
    public mutating func observe(_ infos: [HerdrAgentInfo], now: Date = Date()) -> Observation {
        var listed: [AgentID: (status: AgentStatus, seq: UInt64)] = [:]
        var sessionsNow: [AgentID: String] = [:]
        for info in infos {
            guard !info.paneId.isEmpty, let agent = info.agent, !agent.isEmpty else { continue }
            let id = AgentID(info.paneId)
            listed[id] = (AgentStatus(rawValue: info.agentStatus) ?? .unknown, info.stateChangeSeq)
            if let session = info.sessionIdentity {
                sessionsNow[id] = session
            }
        }

        let moves = carryContinuations(listed: listed, sessionsNow: sessionsNow)

        var enteredAt: [AgentID: Date] = [:]
        for (id, incoming) in listed {
            let incomingSession = sessionsNow[id]
            if var episode = episodes[id],
               episode.status == incoming.status,
               episode.seq == incoming.seq,
               Self.sameOccupant(episode.session, incoming: incomingSession) {
                // A later read that names the session does not open a new
                // episode. A read that omits it does not either: several
                // payloads leave the field off, and that is not a new occupant.
                if let incomingSession {
                    episode.session = incomingSession
                }
                enteredAt[id] = episode.enteredAt
                episodes[id] = episode
            } else {
                let session = incomingSession ?? episodes[id]?.session
                episodes[id] = Episode(
                    status: incoming.status,
                    seq: incoming.seq,
                    enteredAt: now,
                    session: session
                )
                enteredAt[id] = now
            }
        }
        episodes = episodes.filter { listed[$0.key] != nil }
        return Observation(enteredAt: enteredAt, moves: moves)
    }

    /// `lastOutputAt` for one agent, given the detection baseline.
    ///
    /// Working agents with no baseline use `now`. Timing silence from the
    /// episode start when the screen was never read marks a busy agent
    /// quiet. Other statuses do not use the output clock; the caller leaves
    /// `lastOutputAt` alone.
    public static func outputDate(for status: AgentStatus, baseline: Date?, now: Date) -> Date? {
        guard status == .working else { return nil }
        return baseline ?? now
    }

    /// Re-key an episode when one pane with a session disappeared and one
    /// new pane is the only one carrying that session. The episode is
    /// carried only when status and seq still match.
    private mutating func carryContinuations(
        listed: [AgentID: (status: AgentStatus, seq: UInt64)],
        sessionsNow: [AgentID: String]
    ) -> [AgentID: AgentID] {
        var removedBySession: [String: AgentID] = [:]
        var removedAmbiguous: Set<String> = []
        for (id, episode) in episodes where listed[id] == nil {
            guard let session = episode.session, !session.isEmpty else { continue }
            if removedBySession[session] != nil || removedAmbiguous.contains(session) {
                removedAmbiguous.insert(session)
                removedBySession.removeValue(forKey: session)
            } else {
                removedBySession[session] = id
            }
        }

        var addedBySession: [String: AgentID] = [:]
        var addedAmbiguous: Set<String> = []
        for (id, session) in sessionsNow where episodes[id] == nil {
            if addedBySession[session] != nil || addedAmbiguous.contains(session) {
                addedAmbiguous.insert(session)
                addedBySession.removeValue(forKey: session)
            } else {
                addedBySession[session] = id
            }
        }

        var moves: [AgentID: AgentID] = [:]
        for (session, newId) in addedBySession {
            guard !addedAmbiguous.contains(session),
                  !removedAmbiguous.contains(session),
                  let oldId = removedBySession[session],
                  let old = episodes[oldId],
                  let incoming = listed[newId],
                  old.status == incoming.status,
                  old.seq == incoming.seq else { continue }
            episodes[newId] = Episode(
                status: old.status,
                seq: old.seq,
                enteredAt: old.enteredAt,
                session: session
            )
            episodes.removeValue(forKey: oldId)
            moves[oldId] = newId
        }
        return moves
    }

    /// True when `incoming` is the occupant already stored, the first time
    /// that occupant has been named, or a read that did not name one.
    private static func sameOccupant(_ stored: String?, incoming: String?) -> Bool {
        guard let incoming else { return true }
        guard let stored else { return true }
        return stored == incoming
    }
}
