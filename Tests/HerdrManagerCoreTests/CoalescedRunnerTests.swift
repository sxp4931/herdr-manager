import Foundation
import Testing
@testable import HerdrManagerCore

/// A job that counts its runs and, while `holds` is set, waits for
/// `release()` before finishing.
@MainActor
private final class GatedJob {
    private(set) var started = 0
    private(set) var finished = 0
    private(set) var maxConcurrent = 0
    var holds = true
    private var running = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func run() async {
        started += 1
        running += 1
        maxConcurrent = max(maxConcurrent, running)
        if holds {
            await withCheckedContinuation { waiting.append($0) }
        }
        running -= 1
        finished += 1
    }

    func release() {
        let resumed = waiting
        waiting = []
        resumed.forEach { $0.resume() }
    }

    func waitUntilStarted(_ count: Int) async {
        while started < count { await Task.yield() }
    }
}

@Suite("CoalescedRunner", .timeLimit(.minutes(1)))
struct CoalescedRunnerTests {
    @Test("Requests made during a run fold into exactly one follow-up run")
    @MainActor
    func requestsDuringARunFoldIntoOneFollowUp() async {
        // Shepherd started a full diagnosis pass per transition, and the
        // passes overlapped.
        let runner = CoalescedRunner()
        let job = GatedJob()
        let task = runner.request { await job.run() }
        #expect(task != nil)
        await job.waitUntilStarted(1)

        for _ in 0..<5 {
            #expect(runner.request { await job.run() } == nil)
        }
        #expect(job.started == 1)

        job.release()
        await job.waitUntilStarted(2)
        #expect(job.finished == 1)
        job.release()
        await task?.value

        #expect(job.started == 2)
        #expect(job.finished == 2)
        #expect(job.maxConcurrent == 1)
    }

    @Test("Requests made before a run starts share that run")
    @MainActor
    func requestsBeforeStartShareTheRun() async {
        // One snapshot can report several transitions in a row.
        let runner = CoalescedRunner()
        let job = GatedJob()
        job.holds = false
        let task = runner.request { await job.run() }
        #expect(runner.request { await job.run() } == nil)
        #expect(runner.request { await job.run() } == nil)
        await task?.value
        #expect(job.started == 1)
    }

    @Test("A request after the runs finish starts a new run")
    @MainActor
    func requestAfterIdleStartsNewRun() async {
        let runner = CoalescedRunner()
        let job = GatedJob()
        job.holds = false
        await runner.request { await job.run() }?.value
        let second = runner.request { await job.run() }
        #expect(second != nil)
        await second?.value
        #expect(job.started == 2)
    }

    @Test("The follow-up runs the latest job passed")
    @MainActor
    func followUpRunsLatestJob() async {
        let runner = CoalescedRunner()
        let first = GatedJob()
        let latest = GatedJob()
        latest.holds = false
        let task = runner.request { await first.run() }
        await first.waitUntilStarted(1)
        runner.request { await first.run() }
        runner.request { await latest.run() }
        first.release()
        await task?.value
        #expect(first.started == 1)
        #expect(latest.started == 1)
    }
}
