import Foundation
import SQLite3
import Testing
@testable import HerdrManagerCore

@Suite("TokenMeter pricing and windows")
struct TokenMeterPricingTests {
    @Test("Uses the TokenMeter split-input cache formula")
    func splitCost() {
        let pricing = TokenMeterPricing(
            inputPerMillion: 3.0,
            cacheReadPerMillion: 0.30,
            cacheWrite5mPerMillion: 3.75,
            cacheWrite1hPerMillion: 6.0,
            outputPerMillion: 15.0
        )
        let usage = TokenUsage(
            inputTokens: 1_000_000,
            cacheReadTokens: 200_000,
            cacheWrite5mTokens: 100_000,
            cacheWrite1hTokens: 100_000,
            outputTokens: 50_000
        )

        // 600k uncached input + 200k read + 100k 5m write + 100k 1h write
        // + 50k output.
        #expect(abs(pricing.cost(for: usage) - 3.585) < 0.000001)
    }

    @Test("Uses rolling hour and calendar day/week/month boundaries")
    func usageWindows() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = calendar.date(from: DateComponents(
            calendar: calendar, year: 2026, month: 1, day: 15, hour: 15, minute: 30
        ))!

        #expect(UsageWindow.hour.startDate(now: now, calendar: calendar) == now.addingTimeInterval(-3_600))
        #expect(calendar.component(.hour, from: UsageWindow.day.startDate(now: now, calendar: calendar)) == 0)
        #expect(calendar.component(.day, from: UsageWindow.week.startDate(now: now, calendar: calendar)) == 11)
        #expect(calendar.component(.day, from: UsageWindow.month.startDate(now: now, calendar: calendar)) == 1)
    }

    @Test("Resolves model prices and refuses an unknown model fallback")
    func modelSpecificPricing() {
        let book = TokenMeterPriceBook.defaults
        let sonnet = book.pricing(for: .claude, model: "claude-sonnet-4-5-20250929")
        let opus = book.pricing(for: .claude, model: "claude-opus-4-5-20250929")

        #expect(sonnet?.outputPerMillion == 15.0)
        #expect(opus?.outputPerMillion == 25.0)
        #expect(book.pricing(for: .claude, model: "claude-future-9") == nil)
        #expect(book.pricing(for: .codex, model: nil)?.outputPerMillion == 12.0)
    }

    @Test("Supports provider-scoped custom model overrides")
    func customModelPricing() {
        var book = TokenMeterPriceBook(entries: [:])
        let pricing = TokenMeterPricing(inputPerMillion: 1, outputPerMillion: 2)
        book.setModelPricing(pricing, for: .kimi, model: "kimi-k2.5")

        #expect(book.pricing(for: .kimi, model: "kimi-k2.5-20260101") == pricing)
        #expect(book.pricing(for: .grok, model: "kimi-k2.5-20260101") == nil)
    }

    @Test("Uses verified official DeepSeek and Qwen prices")
    func officialPricesForDeepSeekAndQwen() {
        let book = TokenMeterPriceBook.defaults

        let deepseek = book.pricing(for: .deepseek, model: "deepseek-v4-flash-0731")
        #expect(deepseek?.inputPerMillion == 0.14)
        #expect(deepseek?.outputPerMillion == 0.28)
        #expect(deepseek?.cacheReadPerMillion == 0.0028)

        let qwenMax = book.pricing(for: .qwen, model: "qwen3.8-max")
        #expect(qwenMax?.inputPerMillion == 1.65)
        #expect(qwenMax?.outputPerMillion == 4.951)

        let qwenPreview = book.pricing(for: .qwen, model: "qwen3.8-max-preview")
        #expect(qwenPreview?.inputPerMillion == 1.65)

        // The local LM Studio model must hit its $0 entry, not the qwen fallback.
        let local = book.pricing(for: .qwen, model: "qwen3.6-35b-a3b")
        #expect(local?.outputPerMillion == 0.0)

        let glm = book.pricing(for: .qwen, model: "glm-5.2")
        #expect(glm?.inputPerMillion == 1.10)
    }

    @Test("Uses verified official OpenAI and Codex prices")
    func officialOpenAIPrices() {
        let book = TokenMeterPriceBook.defaults

        #expect(book.pricing(for: .codex, model: "gpt-5.6-terra")?.inputPerMillion == 2.0)
        #expect(book.pricing(for: .codex, model: "gpt-5.6-terra")?.outputPerMillion == 12.0)
        #expect(book.pricing(for: .codex, model: "gpt-5.6-luna")?.inputPerMillion == 0.20)
        #expect(book.pricing(for: .codex, model: "gpt-5.6-luna")?.outputPerMillion == 1.20)
        #expect(book.pricing(for: .codex, model: "gpt-5.3-codex")?.inputPerMillion == 1.75)
        #expect(book.pricing(for: .codex, model: "gpt-5.3-codex")?.outputPerMillion == 14.0)
        #expect(book.pricing(for: .codex, model: "codex-auto-review")?.inputPerMillion == 2.0)
        #expect(book.pricing(for: .codex, model: nil)?.inputPerMillion == 2.0)
    }

    @Test("Uses verified official Claude prices")
    func claudeOfficialPrices() {
        let book = TokenMeterPriceBook.defaults

        #expect(book.pricing(for: .claude, model: "claude-sonnet-5")?.inputPerMillion == 2.0)
        #expect(book.pricing(for: .claude, model: "claude-sonnet-5")?.outputPerMillion == 10.0)
        #expect(book.pricing(for: .claude, model: "claude-opus-5")?.outputPerMillion == 25.0)
        #expect(book.pricing(for: .claude, model: "claude-fable-5")?.inputPerMillion == 10.0)
        #expect(book.pricing(for: .claude, model: "claude-fable-5")?.outputPerMillion == 50.0)
        #expect(book.pricing(for: .claude, model: "claude-haiku-4.5")?.inputPerMillion == 1.0)
    }

    @Test("Free and local models price at zero")
    func freeModelsAreZero() {
        let book = TokenMeterPriceBook.defaults

        #expect(book.pricing(for: .qwen, model: "tencent/hy3:free")?.outputPerMillion == 0.0)
        #expect(book.pricing(for: .deepseek, model: "deepseek-v4-flash-free")?.outputPerMillion == 0.0)
    }
}

@Suite("LocalTokenMeter log adapters")
struct LocalTokenMeterTests {
    @Test("Reads Codex cumulative token_count events and attributes one matching agent")
    func readsCodexCumulativeUsage() async throws {
        let home = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let file = home
            .appendingPathComponent(".codex/sessions/2026/01", isDirectory: true)
            .appendingPathComponent("rollout-test.jsonl")
        try writeLines([
            #"{"timestamp":"2026-01-15T11:00:00Z","type":"session_meta","payload":{"id":"session-1","cwd":"/repo"}}"#,
            #"{"timestamp":"2026-01-15T11:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":40,"output_tokens":10}}}}"#,
            #"{"timestamp":"2026-01-15T11:02:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":250,"cached_input_tokens":100,"output_tokens":20}}}}"#,
        ], to: file)

        let agent = Agent(
            id: AgentID("w1:p1"),
            kind: .codex,
            enteredAt: date("2026-01-15T10:00:00Z"),
            cwd: "/repo"
        )
        let meter = LocalTokenMeter(homeDirectory: home)
        let snapshot = await meter.snapshot(
            agents: [agent],
            priceBook: TokenMeterPriceBook.defaults,
            now: date("2026-01-15T13:00:00Z"),
            calendar: utcCalendar()
        )

        let provider = snapshot.providerSummary(for: .codex, window: .day)
        #expect(provider.usage.inputTokens == 250)
        #expect(provider.usage.cacheReadTokens == 100)
        #expect(provider.usage.outputTokens == 20)
        #expect(provider.sessions == 1)
        #expect(provider.costUSD != nil)
        #expect(provider.costIsEstimated) // Codex log did not record a model id.

        let individual = snapshot.agentSummary(for: agent.id, window: .day)
        #expect(individual.usage.totalTokens == 270)
        #expect(snapshot.ambiguousAttributionCount == 0)
    }

    @Test("Reads Claude cache fields and de-duplicates repeated message IDs")
    func readsClaudeUsage() async throws {
        let home = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let project = home.appendingPathComponent(
            ".claude/projects/-repo",
            isDirectory: true
        )
        let file = project.appendingPathComponent("session.jsonl")
        let assistant = #"{"type":"assistant","cwd":"/repo","timestamp":"2026-01-15T11:00:00Z","uuid":"line-1","message":{"id":"message-1","model":"claude-sonnet-4.5","usage":{"input_tokens":10,"cache_creation_input_tokens":20,"cache_read_input_tokens":30,"cache_creation":{"ephemeral_5m_input_tokens":20,"ephemeral_1h_input_tokens":0},"output_tokens":4},"content":[{"type":"tool_use","id":"tool-1"}]}}"#
        try writeLines([assistant, assistant], to: file)

        let agent = Agent(
            id: AgentID("w1:p2"),
            kind: .claude,
            enteredAt: date("2026-01-15T10:00:00Z"),
            cwd: "/repo"
        )
        let meter = LocalTokenMeter(homeDirectory: home)
        let snapshot = await meter.snapshot(
            agents: [agent],
            priceBook: TokenMeterPriceBook.defaults,
            now: date("2026-01-15T13:00:00Z"),
            calendar: utcCalendar()
        )

        let summary = snapshot.providerSummary(for: .claude, window: .day)
        #expect(summary.usage.inputTokens == 60)
        #expect(summary.usage.cacheReadTokens == 30)
        #expect(summary.usage.cacheWrite5mTokens == 20)
        #expect(summary.usage.outputTokens == 4)
        #expect(summary.actions == 1)
        #expect(summary.models == ["claude-sonnet-4.5"])
        #expect(summary.costIsEstimated == false)
        #expect(snapshot.agentSummary(for: agent.id, window: .day).usage.totalTokens == 64)
    }

    @Test("Leaves shared-directory attribution unassigned instead of duplicating it")
    func sharedDirectoryIsAmbiguous() async throws {
        let home = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let file = home
            .appendingPathComponent(".codex/sessions/2026/01", isDirectory: true)
            .appendingPathComponent("rollout-test.jsonl")
        try writeLines([
            #"{"timestamp":"2026-01-15T11:00:00Z","type":"session_meta","payload":{"id":"session-1","cwd":"/repo"}}"#,
            #"{"timestamp":"2026-01-15T11:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":40,"output_tokens":10}}}}"#,
        ], to: file)

        let first = Agent(id: AgentID("w1:p1"), kind: .codex, cwd: "/repo")
        let second = Agent(id: AgentID("w1:p2"), kind: .codex, cwd: "/repo")
        let meter = LocalTokenMeter(homeDirectory: home)
        let snapshot = await meter.snapshot(
            agents: [first, second],
            priceBook: TokenMeterPriceBook.defaults,
            now: date("2026-01-15T13:00:00Z"),
            calendar: utcCalendar()
        )

        #expect(snapshot.ambiguousAttributionCount == 1)
        #expect(snapshot.agentSummary(for: first.id, window: .day).hasUsage == false)
        #expect(snapshot.agentSummary(for: second.id, window: .day).hasUsage == false)
        #expect(snapshot.providerSummary(for: .codex, window: .day).hasUsage)
    }

    @Test("Reads opencode SQLite sessions and attributes the opencode agent")
    func readsOpenCodeDatabase() async throws {
        let home = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let dbURL = home
            .appendingPathComponent(".local/share/opencode", isDirectory: true)
            .appendingPathComponent("opencode.db")
        try writeOpenCodeDatabase(to: dbURL)

        let agent = Agent(
            id: AgentID("w1:opencode"),
            kind: .opencode,
            enteredAt: date("2026-01-15T10:00:00Z"),
            cwd: "/repo"
        )
        let meter = LocalTokenMeter(homeDirectory: home)
        let snapshot = await meter.snapshot(
            agents: [agent],
            priceBook: TokenMeterPriceBook.defaults,
            now: date("2026-01-15T13:00:00Z"),
            calendar: utcCalendar()
        )

        let deepseek = snapshot.providerSummary(for: .deepseek, window: .day)
        // input = 1000 + 200 (write) + 500 (read) = 1700
        #expect(deepseek.usage.inputTokens == 1700)
        // output = 100 + 50 (reasoning) = 150
        #expect(deepseek.usage.outputTokens == 150)
        #expect(deepseek.usage.cacheReadTokens == 500)
        #expect(deepseek.usage.cacheWrite5mTokens == 200)
        #expect(deepseek.costUSD != nil)
        #expect(deepseek.costIsEstimated == false) // model was recorded

        let qwen = snapshot.providerSummary(for: .qwen, window: .day)
        #expect(qwen.usage.inputTokens == 2000)
        #expect(qwen.usage.outputTokens == 300)

        let opencodeAgent = snapshot.agentSummary(for: agent.id, window: .day)
        #expect(opencodeAgent.usage.totalTokens == 1700 + 150 + 2000 + 300)
        #expect(snapshot.ambiguousAttributionCount == 0)

        // Per-model dimension splits totals by the recorded model id.
        let deepseekModel = snapshot.modelSummary(for: "deepseek-v4-flash-0731", window: .day)
        #expect(deepseekModel.usage.inputTokens == 1700)
        #expect(deepseekModel.usage.outputTokens == 150)
        #expect(deepseekModel.costIsEstimated == false)

        let qwenModel = snapshot.modelSummary(for: "qwen3.8-max", window: .day)
        #expect(qwenModel.usage.inputTokens == 2000)
        #expect(qwenModel.usage.outputTokens == 300)
        #expect(
            snapshot.models(withUsageIn: .day)
                == ["deepseek-v4-flash-0731", "qwen3.8-max"]
        )
        #expect(snapshot.modelSummary(for: "unknown-model", window: .day).hasUsage == false)
    }

    private func writeOpenCodeDatabase(to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else {
            throw TestingError.dbOpenFailed
        }
        defer { sqlite3_close(db) }

        let create = """
        CREATE TABLE session (
            id TEXT PRIMARY KEY,
            model TEXT,
            agent TEXT,
            directory TEXT,
            tokens_input INTEGER,
            tokens_output INTEGER,
            tokens_cache_read INTEGER,
            tokens_cache_write INTEGER,
            tokens_reasoning INTEGER,
            time_created INTEGER
        );
        """
        #expect(sqlite3_exec(db, create, nil, nil, nil) == SQLITE_OK)

        let deepseekModel = #"{"id":"deepseek-v4-flash-0731","providerID":"alibaba-token-plan","variant":"max"}"#
        let deepseekTime = Int64(date("2026-01-15T11:00:00Z").timeIntervalSince1970 * 1000)
        let qwenModel = #"{"id":"qwen3.8-max","providerID":"alibaba-token-plan"}"#
        let qwenTime = Int64(date("2026-01-15T12:00:00Z").timeIntervalSince1970 * 1000)

        insertOpenCodeRow(
            db,
            id: "sess-deepseek",
            model: deepseekModel,
            directory: "/repo",
            input: 1000,
            output: 100,
            cacheRead: 500,
            cacheWrite: 200,
            reasoning: 50,
            timeCreated: deepseekTime
        )
        insertOpenCodeRow(
            db,
            id: "sess-qwen",
            model: qwenModel,
            directory: "/repo",
            input: 2000,
            output: 300,
            cacheRead: 0,
            cacheWrite: 0,
            reasoning: 0,
            timeCreated: qwenTime
        )
    }

    private func insertOpenCodeRow(
        _ db: OpaquePointer,
        id: String,
        model: String,
        directory: String,
        input: Int,
        output: Int,
        cacheRead: Int,
        cacheWrite: Int,
        reasoning: Int,
        timeCreated: Int64
    ) {
        let sql = """
        INSERT INTO session (id, model, agent, directory, tokens_input, tokens_output, \
        tokens_cache_read, tokens_cache_write, tokens_reasoning, time_created) \
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, (model as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 3, nil, -1, nil)
        sqlite3_bind_text(stmt, 4, (directory as NSString).utf8String, -1, nil)
        sqlite3_bind_int64(stmt, 5, Int64(input))
        sqlite3_bind_int64(stmt, 6, Int64(output))
        sqlite3_bind_int64(stmt, 7, Int64(cacheRead))
        sqlite3_bind_int64(stmt, 8, Int64(cacheWrite))
        sqlite3_bind_int64(stmt, 9, Int64(reasoning))
        sqlite3_bind_int64(stmt, 10, timeCreated)
        guard sqlite3_step(stmt) == SQLITE_DONE else { return }
    }

    private enum TestingError: Error {
        case dbOpenFailed
    }

    private func makeTemporaryHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("HerdrManagerTokenMeter-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    private func writeLines(_ lines: [String], to file: URL) throws {
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
    }

    private func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func date(_ string: String) -> Date {
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: string)!
    }
}
