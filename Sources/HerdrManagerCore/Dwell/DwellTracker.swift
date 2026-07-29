import Foundation

// MARK: - DwellEntry

public struct DwellEntry: Sendable {
    public let status: AgentStatus
    public let enteredAt: Date
    public let lastOutputAt: Date?

    public init(status: AgentStatus, enteredAt: Date, lastOutputAt: Date?) {
        self.status = status
        self.enteredAt = enteredAt
        self.lastOutputAt = lastOutputAt
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
    private let lock = NSLock()
    private var entries: [AgentID: DwellEntry] = [:]

    public init() {}

    public func update(agentId: AgentID, status: AgentStatus, enteredAt: Date, lastOutputAt: Date?) {
        lock.lock()
        defer { lock.unlock() }
        entries[agentId] = DwellEntry(status: status, enteredAt: enteredAt, lastOutputAt: lastOutputAt)
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
}
