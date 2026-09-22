import Foundation

// MARK: - CoalescedRunner

/// Runs one async job at a time. A request made while a run is in flight
/// is folded into a single follow-up run that starts when it finishes,
/// however many requests arrived meanwhile.
///
/// Shepherd started a full diagnosis pass in its own task on every
/// blocked/working transition, so a burst of transitions ran several
/// passes over the whole herd at once. Folding keeps what a request needs:
/// a run that starts after it was made (a run already going may have read
/// the pane before its transition).
@MainActor
public final class CoalescedRunner {
    private var job: (@MainActor () async -> Void)?
    private var isRunning = false
    private var pending = false

    public init() {}

    /// Ask for a run of `job`. Starts one if none is in flight; otherwise
    /// the run in flight is followed by one more, which runs the latest
    /// `job` passed.
    /// - Returns: The task performing this run and any follow-ups, or nil
    ///   when the request was folded into a task already running.
    @discardableResult
    public func request(_ job: @escaping @MainActor () async -> Void) -> Task<Void, Never>? {
        self.job = job
        pending = true
        guard !isRunning else { return nil }
        isRunning = true
        return Task { await self.drain() }
    }

    private func drain() async {
        // Requests made before a run starts are covered by that run.
        while pending, let job = self.job {
            pending = false
            await job()
        }
        job = nil
        isRunning = false
    }
}
