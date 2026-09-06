import Foundation
#if canImport(CommonCrypto)
import CommonCrypto
#endif

// MARK: - HeartbeatPoller

/// Polls `pane.read(source: .detection)` every 10 seconds for working agents,
/// hashes content, and detects output changes. This is how we detect silence
/// (herdr has no output-change signal).
public actor HeartbeatPoller {

    /// Detection is a screen-sized buffer. Cap the read so a misbehaving
    /// herdr cannot ship full scrollback into RSS.
    nonisolated public static let detectionReadLines = 80

    /// Hash only this many trailing UTF-8 bytes of a detection read. herdr
    /// may ignore `lines` and return a multi-megabyte pane; the newest
    /// output is at the end, so a suffix is enough for change detection.
    nonisolated public static let detectionHashMaxBytes = 64 * 1024

    /// SHA256 hash of last detection read per agent.
    private var hashes: [AgentID: String] = [:]

    /// Last known output timestamps per agent.
    private var lastOutputDates: [AgentID: Date] = [:]

    public init() {}

    /// Poll a set of agents for output changes.
    /// - Parameters:
    ///   - agents: The agents to poll (typically only working agents).
    ///   - adapter: The HerdrAdapter to use for pane reads.
    /// - Returns: A dictionary of AgentID → Date for agents whose output changed.
    public func poll(agents: [Agent], adapter: HerdrAdapter) async -> [AgentID: Date] {
        var updates: [AgentID: Date] = [:]

        // Sequential approach for hash comparison (actor-isolated state)
        for agent in agents {
            let paneId = agent.id.raw  // herdr uses full session-qualified IDs
            do {
                let result = try await adapter.read(
                    paneId: paneId,
                    source: .detection,
                    lines: Self.detectionReadLines
                )
                let hash = Self.sha256(result.text)
                let now = Date()

                if let previousHash = hashes[agent.id] {
                    if hash != previousHash {
                        // Output changed
                        hashes[agent.id] = hash
                        lastOutputDates[agent.id] = now
                        updates[agent.id] = now
                    }
                } else {
                    // First poll — record hash but don't count as a change
                    hashes[agent.id] = hash
                    lastOutputDates[agent.id] = now
                }
            } catch {
                // Read failed — skip this agent
            }
        }

        return updates
    }

    /// Remove tracking for an agent (e.g., when it's closed).
    public func remove(agentId: AgentID) {
        hashes.removeValue(forKey: agentId)
        lastOutputDates.removeValue(forKey: agentId)
    }

    /// Drop hashes for panes that left the herd.
    public func prune(keeping ids: Set<AgentID>) {
        hashes = hashes.filter { ids.contains($0.key) }
        lastOutputDates = lastOutputDates.filter { ids.contains($0.key) }
    }

    /// Clear all tracking state.
    public func clear() {
        hashes.removeAll()
        lastOutputDates.removeAll()
    }

    /// Get the last known output date for an agent.
    public func lastOutputDate(for agentId: AgentID) -> Date? {
        lastOutputDates[agentId]
    }

    // MARK: - SHA256

    /// Compute SHA256 hash of a string, returning a hex string.
    nonisolated static func sha256(_ string: String) -> String {
        var data = Data(string.utf8)
        if data.count > detectionHashMaxBytes {
            data = Data(data.suffix(detectionHashMaxBytes))
        }
        #if canImport(CommonCrypto)
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { ptr in
            _ = CC_SHA256(ptr.baseAddress, CC_LONG(data.count), &digest)
        }
        return digest.map { String(format: "%02x", $0) }.joined()
        #else
        // Fallback: use a simple hash (not cryptographic, but sufficient for change detection)
        var hash: UInt64 = 5381
        for byte in data {
            hash = ((hash << 5) &+ hash) &+ UInt64(byte)
        }
        return String(hash, radix: 16)
        #endif
    }
}
