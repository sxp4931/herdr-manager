import Foundation

// MARK: - SilentEpisode

/// One stretch of silence on one agent, as a diagnosis pass reported it.
public struct SilentEpisode: Equatable, Sendable {
    public let agent: Agent
    /// When the silence clock started (`Verdict.silent(since:)`): the later
    /// of the last output change and the start of the status episode.
    public let since: Date

    /// Names this silence. Output resuming or a status change starts a
    /// silence with a different key.
    public var episodeKey: String {
        "\(agent.id.raw):\(since.timeIntervalSinceReferenceDate)"
    }
}

// MARK: - SilentAlertLedger

/// Decides which silences get an alert after a diagnosis pass. Each silence
/// alerts once, however it ended.
///
/// The app used to key the silent alert by pane and re-arm it only when a
/// diagnosis pass saw that pane's verdict leave silent. The store also
/// resets the verdict on every status change (the agent finished, blocked,
/// or went idle), outside any pass, so a silence that ended that way left
/// the pane marked as alerted, and it never alerted for silence again in
/// that app run. `since` holds still while a pane stays quiet and moves
/// when output resumes or the status changes, so it names the silence.
public struct SilentAlertLedger: Sendable {
    /// The `since` of the silence each pane last alerted for.
    private var alerted: [AgentID: Date] = [:]

    public init() {}

    /// The silences in `agents` that have not alerted yet, now recorded as
    /// alerted. A pane missing from `agents` has left the herd and is
    /// forgotten.
    public mutating func newSilences<S: Sequence>(in agents: S) -> [SilentEpisode] where S.Element == Agent {
        var present: Set<AgentID> = []
        var fresh: [SilentEpisode] = []
        for agent in agents {
            present.insert(agent.id)
            guard AttentionTriage.isActionablySilent(agent),
                  case .silent(let since, _) = agent.verdict,
                  alerted[agent.id] != since else { continue }
            alerted[agent.id] = since
            fresh.append(SilentEpisode(agent: agent, since: since))
        }
        alerted = alerted.filter { present.contains($0.key) }
        return fresh
    }

    /// Panes holding an alerted silence. Internal so tests can check that
    /// panes which left the herd are dropped.
    var trackedCount: Int { alerted.count }
}
