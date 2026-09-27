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

    /// Last known output timestamps per agent. The first look stores one
    /// too; that time is not evidence the screen changed.
    private var lastOutputDates: [AgentID: Date] = [:]

    /// Times a poll compared against this pane's own previous screen and
    /// found a change. A move has to hand the latest one to the new id:
    /// the dictionary `poll` already returned still names the old id, and
    /// the row is gone by the time the store applies it. A first look is
    /// not recorded here.
    private var outputChanges: [AgentID: Date] = [:]

    /// Herd-read serial of the diagnosis that currently owns this poller.
    ///
    /// MCP diagnoses overlap. A poll tagged with an older serial does not
    /// record: that read is the earlier herd, and storing it would replace
    /// the screen a later read just hashed, or plant a first look on a pane
    /// the later read already dropped. An untagged poll always records.
    /// Shepherd does not tag its polls; it has one heartbeat task.
    private var latestPollSerial: UInt64 = 0

    /// Origins whose screen was already carried to a pane id.
    ///
    /// The poll and `pane.moved` both retarget the same hop. Whichever
    /// runs second used to find the origin empty and delete the hash the
    /// first one stored, so the next poll of the new id was a first look
    /// and swallowed the screen the pane landed on. A recorded hop does
    /// nothing the second time, and a hash the old id records after the
    /// move stays on the old id. An origin that has never been polled is
    /// absent, so its replace still drops the previous occupant's hash.
    private var relocatedTo: [AgentID: AgentID] = [:]

    public init() {}

    /// Poll a set of agents for output changes.
    /// - Parameters:
    ///   - agents: The agents to poll (typically only working agents).
    ///   - adapter: The HerdrAdapter to use for pane reads.
    ///   - herdSerial: The herd read this poll belongs to. Omit it and the
    ///     result is always recorded. A serial older than one already noted
    ///     is dropped, including when a newer read notes its serial while
    ///     this one is waiting on `pane.read`.
    /// - Returns: A dictionary of AgentID → Date for agents whose output changed.
    public func poll(
        agents: [Agent],
        adapter: HerdrAdapter,
        herdSerial: UInt64? = nil
    ) async -> [AgentID: Date] {
        note(herdSerial)
        guard acceptsPoll(herdSerial) else { return [:] }
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
                // A newer herd read can have noted its serial during this
                // read. The rest of this poll is the same earlier herd.
                guard acceptsPoll(herdSerial) else { break }

                if let previousHash = hashes[agent.id] {
                    if hash != previousHash {
                        // Output changed. Remember it apart from the
                        // baseline date so a move can carry this time
                        // after `updates` has already been returned.
                        hashes[agent.id] = hash
                        lastOutputDates[agent.id] = now
                        outputChanges[agent.id] = now
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

    /// Carry the detection hash onto the id a cross-workspace move just
    /// published.
    ///
    /// The poll compares a pane's screen to the hash stored for its id. A
    /// move assigns a new id and does not change the screen, so the next
    /// poll of that id would be a first look: the screen the move landed on
    /// is stored and not reported. A pane that just produced output then
    /// stays on the old silence clock until the screen changes again. The
    /// hash moves with the row. An id that has not been polled yet does not
    /// take the destination's hash — that screen belonged to whoever was
    /// there before.
    ///
    /// - Returns: The change already compared on `previous`, now stored
    ///   for `newID`. Nil when that pane has no compared change, which
    ///   includes a screen that has only been seen once. The caller
    ///   writes it onto the row: `poll`'s dictionary still names
    ///   `previous`. A first-look time is not returned; treating it as
    ///   output would end a silence the screen never moved. Nil again
    ///   when this hop already carried the screen: the first caller got
    ///   the time, and a hash recorded on the old id since then stays there.
    @discardableResult
    public func retarget(from previous: AgentID, to newID: AgentID) -> Date? {
        guard previous != newID else { return nil }
        if relocatedTo[previous] == newID {
            return nil
        }
        let hash = hashes.removeValue(forKey: previous)
        let date = lastOutputDates.removeValue(forKey: previous)
        if hash != nil || date != nil || outputChanges[previous] != nil {
            relocatedTo[previous] = newID
        }
        if let hash {
            hashes[newID] = hash
        } else {
            hashes.removeValue(forKey: newID)
        }
        if let date {
            lastOutputDates[newID] = date
        } else {
            lastOutputDates.removeValue(forKey: newID)
        }
        return parkOutputChange(from: previous, onto: newID, replacingDestination: true)
    }

    /// Replace every moved pane's hash before returning.
    ///
    /// One call is one turn of this actor, so a vacant retarget or a
    /// prune cannot run between the panes of a single poll. Each hop
    /// still follows `retarget(from:to:)`, including a hop that already
    /// moved and an origin that was never polled.
    public func retarget(
        replacing moves: [AgentID: AgentID],
        herdSerial: UInt64? = nil
    ) -> [AgentID: Date] {
        // A poll waiting on pane.read resumes only after this call returns.
        // Noting the serial first is what makes that poll drop its bytes
        // instead of storing them over the hashes moved here.
        note(herdSerial)
        var carried: [AgentID: Date] = [:]
        for (from, to) in moves {
            if let date = retarget(from: from, to: to) {
                carried[to] = date
            }
        }
        return carried
    }

    /// Move the origin's hash onto `newID` only when that id has none.
    ///
    /// A poll applied before `pane.moved` may already have hashed the new
    /// id: that screen is the mover's, and replacing it would report the
    /// same screen again. An id that has not been polled yet still needs
    /// the hash the move carried, or the next read is a first look and
    /// swallows the screen the pane landed on. An origin that was never
    /// polled does not clear a hash the destination already stored.
    ///
    /// - Returns: The origin's compared change, including when `newID`
    ///   already has a hash. That hash is the mover's screen, so the next
    ///   poll will not report the change again. The later of the two
    ///   parked changes stays on `newID` for the move after this one.
    @discardableResult
    public func retargetVacant(from previous: AgentID, to newID: AgentID) -> Date? {
        guard previous != newID else { return nil }
        let hash = hashes.removeValue(forKey: previous)
        let date = lastOutputDates.removeValue(forKey: previous)
        // The poll's replace of this same hop may still be waiting. Remember
        // the move before that replace sees an empty origin and clears
        // `newID`. A never-polled origin records nothing.
        if hash != nil || date != nil || outputChanges[previous] != nil {
            relocatedTo[previous] = newID
        }
        if hashes[newID] == nil, let hash {
            hashes[newID] = hash
        }
        if lastOutputDates[newID] == nil, let date {
            lastOutputDates[newID] = date
        }
        return parkOutputChange(from: previous, onto: newID, replacingDestination: false)
    }

    /// Move a compared change onto `newID`. The baseline date stays in
    /// `lastOutputDates` and is not parked here.
    private func parkOutputChange(
        from previous: AgentID,
        onto newID: AgentID,
        replacingDestination: Bool
    ) -> Date? {
        let carried = outputChanges.removeValue(forKey: previous)
        if replacingDestination {
            if let carried {
                outputChanges[newID] = carried
            } else {
                outputChanges.removeValue(forKey: newID)
            }
            return carried
        }
        guard let carried else { return nil }
        if let existing = outputChanges[newID], existing >= carried {
            return carried
        }
        outputChanges[newID] = carried
        return carried
    }

    /// Remember a herd-read serial that did not retarget or poll.
    ///
    /// A diagnosis whose panes are all blocked still owns the poller. An
    /// in-flight poll of an earlier read has to notice that before it
    /// stores, or its screen replaces this herd's.
    public func noteHerdSerial(_ serial: UInt64) {
        note(serial)
    }

    /// Raise the poll serial. A smaller one is an earlier read and stays behind.
    private func note(_ serial: UInt64?) {
        guard let serial, serial > latestPollSerial else { return }
        latestPollSerial = serial
    }

    /// Untagged polls record. A tagged poll records only while its serial
    /// is the one most recently noted. Zero is not a serial: a caller that
    /// failed to capture one must not count as the current herd.
    private func acceptsPoll(_ herdSerial: UInt64?) -> Bool {
        guard let herdSerial else { return true }
        guard herdSerial > 0 else { return false }
        return herdSerial == latestPollSerial
    }

    /// Remove tracking for an agent (e.g., when it's closed).
    public func remove(agentId: AgentID) {
        hashes.removeValue(forKey: agentId)
        lastOutputDates.removeValue(forKey: agentId)
        outputChanges.removeValue(forKey: agentId)
        // The origin has already left. A tombstone keyed by it still stops
        // a late replace from clearing the id the screen moved to. Drop
        // only the ones that pointed at the row that just left.
        relocatedTo = relocatedTo.filter { $0.value != agentId }
    }

    /// Drop hashes for panes that left the herd.
    ///
    /// A tombstone stays while its destination is still in the herd. The
    /// origin is the id that left, and the replace that needs the tombstone
    /// has not necessarily run yet. Dropping it here is what lets that
    /// replace delete the moved screen.
    public func prune(keeping ids: Set<AgentID>) {
        hashes = hashes.filter { ids.contains($0.key) }
        lastOutputDates = lastOutputDates.filter { ids.contains($0.key) }
        outputChanges = outputChanges.filter { ids.contains($0.key) }
        relocatedTo = relocatedTo.filter { ids.contains($0.value) }
    }

    /// Clear all tracking state.
    public func clear() {
        hashes.removeAll()
        lastOutputDates.removeAll()
        outputChanges.removeAll()
        relocatedTo.removeAll()
        latestPollSerial = 0
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
