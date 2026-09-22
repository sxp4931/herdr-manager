import Foundation
import Testing
@testable import HerdrManagerCore

@Suite("JSONLLineReader resume points")
struct JSONLResumePointTests {
    private struct Line: Equatable {
        let number: Int
        let text: String
        let terminated: Bool
    }

    @Test("The resume point stays before an unterminated last line")
    func resumePointSkipsUnterminatedTail() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("HerdrManagerJSONL-resume-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: file) }
        try "a\nb".write(to: file, atomically: true, encoding: .utf8)

        var delivered: [Line] = []
        let first = JSONLLineReader.forEachLine(in: file, resumingAt: .start) { number, data, terminated in
            delivered.append(Line(number: number, text: String(decoding: data, as: UTF8.self), terminated: terminated))
        }
        #expect(delivered == [
            Line(number: 0, text: "a", terminated: true),
            Line(number: 1, text: "b", terminated: false),
        ])
        #expect(first?.resumePoint == JSONLResumePoint(offset: 2, lineNumber: 1))
        #expect(first?.bytesRead == 3)
        #expect(JSONLLineReader.signature(of: file, endingAt: 2) == Data("a\n".utf8))

        // The writer finished "b" and added a line.
        try "a\nbc\nd\n".write(to: file, atomically: true, encoding: .utf8)
        let point = try #require(first?.resumePoint)
        delivered.removeAll()
        let resumed = JSONLLineReader.forEachLine(in: file, resumingAt: point) { number, data, terminated in
            delivered.append(Line(number: number, text: String(decoding: data, as: UTF8.self), terminated: terminated))
        }
        #expect(delivered == [
            Line(number: 1, text: "bc", terminated: true),
            Line(number: 2, text: "d", terminated: true),
        ])
        #expect(resumed?.resumePoint == JSONLResumePoint(offset: 7, lineNumber: 3))
        #expect(resumed?.bytesRead == 5)
    }

    @Test("An oversized line skipped mid-file still advances the resume point")
    func oversizedLineAdvancesResumePoint() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("HerdrManagerJSONL-resume-big-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: file) }
        let junk = String(repeating: "q", count: JSONLLineReader.maxLineBytes + JSONLLineReader.chunkSize)
        let text = "{\"keep\":1}\n\(junk)\n"
        try text.write(to: file, atomically: true, encoding: .utf8)

        var lines = 0
        let result = JSONLLineReader.forEachLine(in: file, resumingAt: .start) { _, _, _ in
            lines += 1
        }
        #expect(lines == 1)
        #expect(result?.resumePoint == JSONLResumePoint(offset: UInt64(text.utf8.count), lineNumber: 2))
    }

    @Test("A signature past the end of a shrunken file is nil")
    func signaturePastEndIsNil() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("HerdrManagerJSONL-sig-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: file) }
        try "short\n".write(to: file, atomically: true, encoding: .utf8)

        #expect(JSONLLineReader.signature(of: file, endingAt: 0) == Data())
        #expect(JSONLLineReader.signature(of: file, endingAt: 6) == Data("short\n".utf8))
        #expect(JSONLLineReader.signature(of: file, endingAt: 600) == nil)
    }
}

@Suite("Token meter reads append-only logs incrementally")
struct TokenMeterAppendOnlyTests {
    @Test("A grown Codex log is read from where the last refresh stopped")
    func grownCodexLogReadsOnlyAppendedBytes() async throws {
        let home = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let file = codexFile(in: home)
        let head = lines([codexMeta(), codexTokens(at: "11:01", input: 100, output: 10)])
        try write(head, to: file)

        let meter = LocalTokenMeter(homeDirectory: home)
        _ = await snapshot(meter)
        let firstRead = await meter.lastSnapshotLogBytesRead
        #expect(firstRead == UInt64(head.utf8.count))

        _ = await snapshot(meter)
        let unchangedRead = await meter.lastSnapshotLogBytesRead
        #expect(unchangedRead == 0)

        let tail = lines([codexTokens(at: "11:02", input: 400, output: 40)])
        try append(tail, to: file)
        let grown = await snapshot(meter)
        let appendRead = await meter.lastSnapshotLogBytesRead
        #expect(appendRead == UInt64(tail.utf8.count))

        let day = grown.providerSummary(for: .codex, window: .day)
        #expect(day.usage.inputTokens == 400)
        #expect(day.usage.outputTokens == 40)
        let fresh = await snapshot(LocalTokenMeter(homeDirectory: home))
        #expect(grown.providerSummary(for: .codex, window: .allTime)
            == fresh.providerSummary(for: .codex, window: .allTime))
    }

    @Test("A last line finished after a refresh is re-read and counted once")
    func unterminatedCodexLineCountsOnce() async throws {
        let home = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let file = codexFile(in: home)
        let tailLine = codexTokens(at: "11:02", input: 250, output: 25)
        try write(
            lines([codexMeta(), codexTokens(at: "11:01", input: 100, output: 10)]) + tailLine,
            to: file
        )

        let meter = LocalTokenMeter(homeDirectory: home)
        let first = await snapshot(meter)
        #expect(first.providerSummary(for: .codex, window: .day).usage.inputTokens == 250)

        let appended = "\n" + lines([codexTokens(at: "11:03", input: 400, output: 40)])
        try append(appended, to: file)
        let grown = await snapshot(meter)
        // The unterminated line is read again; nothing before it is.
        let read = await meter.lastSnapshotLogBytesRead
        #expect(read == UInt64((tailLine + appended).utf8.count))

        let day = grown.providerSummary(for: .codex, window: .day)
        #expect(day.usage.inputTokens == 400)
        #expect(day.usage.outputTokens == 40)
        let fresh = await snapshot(LocalTokenMeter(homeDirectory: home))
        #expect(grown.providerSummary(for: .codex, window: .allTime)
            == fresh.providerSummary(for: .codex, window: .allTime))
    }

    @Test("A line caught half-written is counted once it is complete")
    func halfWrittenCodexLineCountsWhenComplete() async throws {
        let home = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let file = codexFile(in: home)
        let pendingLine = codexTokens(at: "11:02", input: 250, output: 25)
        let split = pendingLine.index(pendingLine.startIndex, offsetBy: pendingLine.count / 2)
        try write(
            lines([codexMeta(), codexTokens(at: "11:01", input: 100, output: 10)])
                + String(pendingLine[..<split]),
            to: file
        )

        let meter = LocalTokenMeter(homeDirectory: home)
        let first = await snapshot(meter)
        #expect(first.providerSummary(for: .codex, window: .day).usage.inputTokens == 100)

        try append(String(pendingLine[split...]) + "\n", to: file)
        let completed = await snapshot(meter)
        #expect(completed.providerSummary(for: .codex, window: .day).usage.inputTokens == 250)
        #expect(completed.providerSummary(for: .codex, window: .day).usage.outputTokens == 25)
    }

    @Test("Claude usage repeated across a refresh counts once and keeps the logged cwd")
    func claudeRepeatedMessageAcrossRefresh() async throws {
        let home = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        // The project directory does not match the agent, so attribution
        // relies on the cwd logged in the first read, carried in the saved
        // parser state.
        let file = home
            .appendingPathComponent(".claude/projects/-elsewhere", isDirectory: true)
            .appendingPathComponent("session.jsonl")
        let cwdLine = #"{"type":"user","cwd":"/repo","timestamp":"2026-01-15T10:59:00Z","uuid":"line-0"}"#
        let messageOne = #"{"type":"assistant","timestamp":"2026-01-15T11:00:00Z","uuid":"line-1","message":{"id":"message-1","model":"claude-sonnet-4.5","usage":{"input_tokens":10,"cache_creation_input_tokens":20,"cache_read_input_tokens":30,"cache_creation":{"ephemeral_5m_input_tokens":20,"ephemeral_1h_input_tokens":0},"output_tokens":4}}}"#
        let messageOneAgain = messageOne.replacingOccurrences(of: #""uuid":"line-1""#, with: #""uuid":"line-2""#)
        let messageTwo = #"{"type":"assistant","timestamp":"2026-01-15T11:05:00Z","uuid":"line-3","message":{"id":"message-2","model":"claude-sonnet-4.5","usage":{"input_tokens":7,"output_tokens":3}}}"#
        try write(lines([cwdLine, messageOne]), to: file)

        let agent = Agent(
            id: AgentID("w1:p2"),
            kind: .claude,
            enteredAt: date("2026-01-15T10:00:00Z"),
            cwd: "/repo"
        )
        let meter = LocalTokenMeter(homeDirectory: home)
        _ = await snapshot(meter, agents: [agent])

        try append(lines([messageOneAgain, messageTwo]), to: file)
        let grown = await snapshot(meter, agents: [agent])

        let day = grown.providerSummary(for: .claude, window: .day)
        #expect(day.usage.inputTokens == 67)
        #expect(day.usage.outputTokens == 7)
        #expect(grown.agentSummary(for: agent.id, window: .day).usage.totalTokens == 74)
        let fresh = await snapshot(LocalTokenMeter(homeDirectory: home), agents: [agent])
        #expect(grown.providerSummary(for: .claude, window: .allTime)
            == fresh.providerSummary(for: .claude, window: .allTime))
        #expect(grown.agentSummary(for: agent.id, window: .allTime)
            == fresh.agentSummary(for: agent.id, window: .allTime))
    }

    @Test("An agent starting or stopping in a Claude project does not re-read its transcripts")
    func claudeTranscriptSurvivesHerdChange() async throws {
        let home = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        // No cwd is logged, so attribution relies on the project directory.
        let file = home
            .appendingPathComponent(".claude/projects/-repo", isDirectory: true)
            .appendingPathComponent("session.jsonl")
        let transcript = lines([
            #"{"type":"assistant","timestamp":"2026-01-15T11:00:00Z","uuid":"line-1","message":{"id":"message-1","model":"claude-sonnet-4.5","usage":{"input_tokens":10,"output_tokens":4}}}"#,
        ])
        try write(transcript, to: file)

        let meter = LocalTokenMeter(homeDirectory: home)
        // The first refresh after launch runs before the herd has loaded.
        _ = await snapshot(meter)
        let launchRead = await meter.lastSnapshotLogBytesRead
        #expect(launchRead == UInt64(transcript.utf8.count))

        let agent = Agent(
            id: AgentID("w1:p2"),
            kind: .claude,
            enteredAt: date("2026-01-15T10:00:00Z"),
            cwd: "/repo"
        )
        let started = await snapshot(meter, agents: [agent])
        let startedRead = await meter.lastSnapshotLogBytesRead
        #expect(startedRead == 0)
        #expect(started.agentSummary(for: agent.id, window: .day).usage.totalTokens == 14)

        let stopped = await snapshot(meter)
        let stoppedRead = await meter.lastSnapshotLogBytesRead
        #expect(stoppedRead == 0)
        #expect(stopped.agentSummary(for: agent.id, window: .day).hasUsage == false)
        #expect(stopped.providerSummary(for: .claude, window: .day).usage.totalTokens == 14)
    }

    @Test("The Kimi model logged before a refresh prices usage appended after it")
    func kimiModelCarriesAcrossRefresh() async throws {
        let home = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let session = home.appendingPathComponent("kimi-sessions/s1", isDirectory: true)
        let wire = session.appendingPathComponent("agents/main/wire.jsonl")
        try write(
            lines([#"{"sessionDir":"\#(session.path)","workDir":"/repo"}"#]),
            to: home.appendingPathComponent(".kimi-code/session_index.jsonl")
        )
        try write(lines([
            #"{"type":"llm.request","modelAlias":"kimi-k3","time":1768474800000}"#,
            kimiUsage(time: 1_768_474_800_000, input: 100, output: 10),
        ]), to: wire)

        let meter = LocalTokenMeter(homeDirectory: home)
        _ = await snapshot(meter)
        try append(lines([kimiUsage(time: 1_768_475_100_000, input: 50, output: 5)]), to: wire)
        let grown = await snapshot(meter)

        let model = grown.modelSummary(for: "kimi-k3", window: .day)
        #expect(model.usage.inputTokens == 150)
        #expect(model.usage.outputTokens == 15)
        #expect(grown.providerSummary(for: .kimi, window: .day).hasUnpricedUsage == false)
        let fresh = await snapshot(LocalTokenMeter(homeDirectory: home))
        #expect(grown.providerSummary(for: .kimi, window: .allTime)
            == fresh.providerSummary(for: .kimi, window: .allTime))
    }

    @Test("A log rewritten with different bytes is read again from the start")
    func rewrittenLogIsReadFromStart() async throws {
        let home = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let file = codexFile(in: home)
        try write(lines([codexMeta(id: "session-a"), codexTokens(at: "11:01", input: 100, output: 10)]), to: file)

        let meter = LocalTokenMeter(homeDirectory: home)
        _ = await snapshot(meter)

        let rewritten = lines([
            codexMeta(id: "session-b"),
            codexTokens(at: "11:04", input: 50, output: 5),
            codexTokens(at: "11:05", input: 70, output: 7),
            codexTokens(at: "11:06", input: 90, output: 9),
        ])
        try write(rewritten, to: file)
        let after = await snapshot(meter)
        let read = await meter.lastSnapshotLogBytesRead
        #expect(read == UInt64(rewritten.utf8.count))

        let day = after.providerSummary(for: .codex, window: .day)
        #expect(day.usage.inputTokens == 90)
        #expect(day.sessions == 1)
        let fresh = await snapshot(LocalTokenMeter(homeDirectory: home))
        #expect(after.providerSummary(for: .codex, window: .allTime)
            == fresh.providerSummary(for: .codex, window: .allTime))
    }

    @Test("A log that shrank is read again from the start")
    func truncatedLogIsReadFromStart() async throws {
        let home = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let file = codexFile(in: home)
        try write(lines([
            codexMeta(),
            codexTokens(at: "11:01", input: 100, output: 10),
            codexTokens(at: "11:02", input: 250, output: 25),
        ]), to: file)

        let meter = LocalTokenMeter(homeDirectory: home)
        _ = await snapshot(meter)

        let truncated = lines([codexMeta(), codexTokens(at: "11:01", input: 100, output: 10)])
        try write(truncated, to: file)
        let after = await snapshot(meter)
        let read = await meter.lastSnapshotLogBytesRead
        #expect(read == UInt64(truncated.utf8.count))
        #expect(after.providerSummary(for: .codex, window: .day).usage.inputTokens == 100)
    }

    @Test("An old unfinished last line is not folded, so finishing it later does not double count")
    func oldUnterminatedLineIsNotFolded() async throws {
        let home = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let file = codexFile(in: home)
        // December history sits before January's compaction cutoff, so it
        // is folded, except the unterminated line that will be read again.
        try write(
            lines([
                codexMeta(timestamp: "2025-12-10T09:00:00Z"),
                codexTokens(timestamp: "2025-12-10T10:00:00Z", input: 100, output: 10),
            ]) + codexTokens(timestamp: "2025-12-10T11:00:00Z", input: 300, output: 30),
            to: file
        )

        let meter = LocalTokenMeter(homeDirectory: home)
        let first = await snapshot(meter)
        #expect(first.overallSummary(for: .allTime).usage.inputTokens == 300)

        try append("\n" + lines([codexTokens(at: "11:00", input: 600, output: 60)]), to: file)
        let grown = await snapshot(meter)
        #expect(grown.overallSummary(for: .allTime).usage.inputTokens == 600)
        #expect(grown.overallSummary(for: .allTime).usage.outputTokens == 60)
        let fresh = await snapshot(LocalTokenMeter(homeDirectory: home))
        #expect(grown.overallSummary(for: .allTime) == fresh.overallSummary(for: .allTime))
    }

    // MARK: - Fixtures

    private func codexFile(in home: URL) -> URL {
        home
            .appendingPathComponent(".codex/sessions/2026/01", isDirectory: true)
            .appendingPathComponent("rollout-append.jsonl")
    }

    private func codexMeta(id: String = "session-append", timestamp: String = "2026-01-15T11:00:00Z") -> String {
        #"{"timestamp":"\#(timestamp)","type":"session_meta","payload":{"id":"\#(id)","cwd":"/repo"}}"#
    }

    private func codexTokens(at time: String, input: Int, output: Int) -> String {
        codexTokens(timestamp: "2026-01-15T\(time):00Z", input: input, output: output)
    }

    private func codexTokens(timestamp: String, input: Int, output: Int) -> String {
        #"{"timestamp":"\#(timestamp)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\#(input),"cached_input_tokens":0,"output_tokens":\#(output)}}}}"#
    }

    private func kimiUsage(time: Int, input: Int, output: Int) -> String {
        #"{"type":"usage.record","usageScope":"turn","time":\#(time),"usage":{"inputOther":\#(input),"inputCacheRead":0,"inputCacheCreation":0,"output":\#(output)}}"#
    }

    /// Newline-terminated lines.
    private func lines(_ lines: [String]) -> String {
        lines.map { $0 + "\n" }.joined()
    }

    private func snapshot(_ meter: LocalTokenMeter, agents: [Agent] = []) async -> TokenMeterSnapshot {
        await meter.snapshot(
            agents: agents,
            priceBook: TokenMeterPriceBook.defaults,
            now: date("2026-01-15T13:00:00Z"),
            calendar: utcCalendar()
        )
    }

    private func makeTemporaryHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("HerdrManagerTokenMeter-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    private func write(_ text: String, to file: URL) throws {
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try text.write(to: file, atomically: true, encoding: .utf8)
    }

    private func append(_ text: String, to file: URL) throws {
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    private func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func date(_ string: String) -> Date {
        ISO8601DateFormatter().date(from: string)!
    }
}
