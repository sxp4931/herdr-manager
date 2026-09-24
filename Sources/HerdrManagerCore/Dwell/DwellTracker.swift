import Foundation

// MARK: - DwellEntry

public struct DwellEntry: Sendable {
    public let status: AgentStatus
    public let enteredAt: Date
    public let lastOutputAt: Date?
    /// Stable identity of the agent occupying the pane (e.g. the AgentKind
    /// description). Used as a restore guard: a persisted entry is only
    /// reinstated if the current occupant's fingerprint still matches.
    public let occupantFingerprint: String
    /// The agent's `stateChangeSeq` at the time the entry was recorded.
    /// Combined with `occupantFingerprint`, this guards against restoring
    /// a stale dwell episode after the pane has been reused by a different
    /// agent session or the status episode has advanced.
    public let stateChangeSeq: UInt64

    public init(
        status: AgentStatus,
        enteredAt: Date,
        lastOutputAt: Date?,
        occupantFingerprint: String = "",
        stateChangeSeq: UInt64 = 0
    ) {
        self.status = status
        self.enteredAt = enteredAt
        self.lastOutputAt = lastOutputAt
        self.occupantFingerprint = occupantFingerprint
        self.stateChangeSeq = stateChangeSeq
    }

    public var dwellDuration: TimeInterval {
        Date().timeIntervalSince(enteredAt)
    }

    public var timeSinceOutput: TimeInterval? {
        guard let lastOutputAt else { return nil }
        return Date().timeIntervalSince(lastOutputAt)
    }
}

// MARK: - DwellTracker

public final class DwellTracker: @unchecked Sendable {
    /// Persisted dwell JSON is a compact map. A larger file is not read at
    /// launch, and a snapshot that would encode larger is not written.
    public static let maxFileBytes = 256 * 1024

    private let lock = NSLock()
    private var entries: [AgentID: DwellEntry] = [:]

    /// On-disk location for the persisted dwell state. Lazily resolved so
    /// tests can override it via `init(fileURL:)`.
    private let fileURL: URL

    public init() {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        let dir = appSupport.appendingPathComponent("HerdrManager", isDirectory: true)
        self.fileURL = dir.appendingPathComponent("dwell-state.json")
    }

    /// Testable initializer with an explicit file location.
    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func update(
        agentId: AgentID,
        status: AgentStatus,
        enteredAt: Date,
        lastOutputAt: Date?,
        occupantFingerprint: String = "",
        stateChangeSeq: UInt64 = 0
    ) {
        lock.lock()
        defer { lock.unlock() }
        entries[agentId] = DwellEntry(
            status: status,
            enteredAt: enteredAt,
            lastOutputAt: lastOutputAt,
            occupantFingerprint: occupantFingerprint,
            stateChangeSeq: stateChangeSeq
        )
    }

    /// Record each live agent's current episode and forget every pane that
    /// is not in `liveAgents`. Panes that closed or exited used to stay in
    /// the map, and in every save, for the rest of the run.
    public func sync(liveAgents: [AgentID: Agent]) {
        var live: [AgentID: DwellEntry] = [:]
        for (agentId, agent) in liveAgents {
            live[agentId] = DwellEntry(
                status: agent.status,
                enteredAt: agent.enteredAt,
                lastOutputAt: agent.lastOutputAt,
                occupantFingerprint: Self.fingerprint(for: agent),
                stateChangeSeq: agent.stateChangeSeq
            )
        }
        lock.lock()
        defer { lock.unlock() }
        entries = live
    }

    public func remove(agentId: AgentID) {
        lock.lock()
        defer { lock.unlock() }
        entries.removeValue(forKey: agentId)
    }

    public func entry(for agentId: AgentID) -> DwellEntry? {
        lock.lock()
        defer { lock.unlock() }
        return entries[agentId]
    }

    public func dwellDuration(for agentId: AgentID) -> TimeInterval? {
        entry(for: agentId)?.dwellDuration
    }

    public func timeSinceOutput(for agentId: AgentID) -> TimeInterval? {
        entry(for: agentId)?.timeSinceOutput
    }

    public func allEntries() -> [AgentID: DwellEntry] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }

    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll()
    }

    // MARK: - Persistence

    /// Persist the current dwell entries to disk.
    ///
    /// Creates the parent directory with 0700 if needed and writes the file
    /// atomically with 0600. Errors are swallowed — dwell persistence is
    /// best-effort and must never break the live tracking path.
    ///
    /// A snapshot that encodes past `maxFileBytes` is not written (load
    /// would refuse it); the file on disk stays as it is until a later
    /// snapshot fits. An oversized file on disk is replaced by the first one
    /// that does, so persistence recovers once the herd is small again.
    public func save() {
        lock.lock()
        let snapshot = entries
        lock.unlock()

        let persisted = PersistedDwellState(
            entries: snapshot.map { PersistedDwellEntry(agentId: $0.key, entry: $0.value) }
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(persisted),
              data.count <= Self.maxFileBytes else { return }

        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        // Write atomically, then tighten file permissions to 0600.
        do {
            try data.write(to: fileURL, options: .atomic)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: fileURL.path
            )
        } catch {
            // Best-effort — drop the write rather than propagate.
        }
    }

    /// Restore dwell entries from disk, guarded by occupant identity.
    ///
    /// A stored entry is reinstated ONLY when the current agent at the same
    /// AgentID has a matching `occupantFingerprint`, `status`, AND a
    /// non-zero `stateChangeSeq`. Mismatches (pane reused, different agent,
    /// status episode advanced) discard the stale episode so we never carry
    /// forward bogus dwell. Entries with no live match are dropped, so the
    /// next save rewrites the file with the live herd only.
    ///
    /// A seq of 0 means herdr gave no seq, and a fresh agent starts there:
    /// after a herdr restart, a reused pane id running the same kind would
    /// match on kind alone and inherit a dead episode's `enteredAt`. A
    /// non-zero seq still collides when the reused pane reaches the same
    /// seq and status; `agent.list` carries no server instance id to rule
    /// that out, and the cost is one wrong dwell start, which resets at the
    /// pane's next transition.
    ///
    /// - Parameter currentAgents: The live agent map to validate against.
    ///   Typically `AgentStore.agents` at the time of restore.
    /// - Returns: The restored entries keyed by agent id, so callers can apply
    ///   the persisted dwell timestamps back onto the live agents.
    @discardableResult
    public func load(currentAgents: [AgentID: Agent]) -> [AgentID: DwellEntry] {
        var restored: [AgentID: DwellEntry] = [:]
        // An oversized file is not read. It is not a reason to stop saving:
        // the next save replaces it with the live herd.
        if !fileIsOversized(),
           let data = BoundedFileRead.data(from: fileURL, maxBytes: Self.maxFileBytes),
           let persisted = try? JSONDecoder().decode(PersistedDwellState.self, from: data) {
            for item in persisted.entries {
                let agentId = item.agentId
                guard let current = currentAgents[agentId] else { continue }

                // Restore guard: fingerprint, status, and a real seq must match.
                guard current.stateChangeSeq != 0,
                      current.stateChangeSeq == item.stateChangeSeq,
                      current.status == item.status,
                      Self.fingerprint(for: current) == item.occupantFingerprint
                else { continue }

                restored[agentId] = DwellEntry(
                    status: item.status,
                    enteredAt: item.enteredAt,
                    lastOutputAt: item.lastOutputAt,
                    occupantFingerprint: item.occupantFingerprint,
                    stateChangeSeq: item.stateChangeSeq
                )
            }
        }

        lock.lock()
        entries = entries
            .filter { currentAgents[$0.key] != nil }
            .merging(restored) { _, persisted in persisted }
        lock.unlock()
        return restored
    }

    private func fileIsOversized() -> Bool {
        guard let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
              values.isRegularFile == true,
              let size = values.fileSize else {
            return false
        }
        return size > Self.maxFileBytes
    }

    /// Derive a stable occupant fingerprint from an Agent. Uses the kind's
    /// raw description so two different agent runtimes (e.g. "claude" vs
    /// "opencode") never collide on the same pane.
    internal static func fingerprint(for agent: Agent) -> String {
        switch agent.kind {
        case .claude: return "claude"
        case .codex: return "codex"
        case .opencode: return "opencode"
        case .aider: return "aider"
        case .gemini: return "gemini"
        case .custom(let name): return "custom:\(name)"
        }
    }

    // MARK: - Persisted Codable shapes

    private struct PersistedDwellEntry: Codable {
        let agentId: AgentID
        let status: AgentStatus
        let enteredAt: Date
        let lastOutputAt: Date?
        let occupantFingerprint: String
        let stateChangeSeq: UInt64

        init(agentId: AgentID, entry: DwellEntry) {
            self.agentId = agentId
            self.status = entry.status
            self.enteredAt = entry.enteredAt
            self.lastOutputAt = entry.lastOutputAt
            self.occupantFingerprint = entry.occupantFingerprint
            self.stateChangeSeq = entry.stateChangeSeq
        }
    }

    private struct PersistedDwellState: Codable {
        let entries: [PersistedDwellEntry]
    }
}
