import Foundation
import SQLite3

/// Reads the local session logs used by the supported coding-agent CLIs
/// and Cursor's local chat store / herdr-usage JSONL.
///
/// The actor owns all file I/O so a large transcript cannot block Shepherd's
/// menu-bar main actor. It never writes to, tails, or uploads the log files.
public actor LocalTokenMeter {
    private let homeDirectory: URL
    private let iso8601Formatter: ISO8601DateFormatter

    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.homeDirectory = homeDirectory
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.iso8601Formatter = formatter
    }

    public func snapshot(
        agents: [Agent],
        priceBook: TokenMeterPriceBook,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> TokenMeterSnapshot {
        var cwdHints: [String: String] = [:]
        for agent in agents {
            guard let cwd = normalizedPath(agent.cwd), !cwd.isEmpty else { continue }
            cwdHints[claudeProjectKey(for: cwd)] = cwd
        }

        var events: [TokenUsageEvent] = []
        events.append(contentsOf: scanClaude(cwdHints: cwdHints))
        events.append(contentsOf: scanCodex())
        events.append(contentsOf: scanKimi())
        events.append(contentsOf: scanGrok())
        events.append(contentsOf: scanCursor())
        events.append(contentsOf: scanOpenCode())

        return TokenMeterAggregator.snapshot(
            events: events,
            agents: agents,
            priceBook: priceBook,
            now: now,
            calendar: calendar
        )
    }

    // MARK: - Claude Code

    private func scanClaude(cwdHints: [String: String]) -> [TokenUsageEvent] {
        let root = homeDirectory.appendingPathComponent(".claude/projects", isDirectory: true)
        guard let projectDirectories = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var result: [TokenUsageEvent] = []
        for project in projectDirectories where isDirectory(project) {
            let projectHint = cwdHints[project.lastPathComponent]
            for file in jsonlFiles(in: project) {
                result.append(contentsOf: scanClaudeTranscript(file, cwdHint: projectHint))
            }
        }
        return result
    }

    private func scanClaudeTranscript(_ file: URL, cwdHint: String?) -> [TokenUsageEvent] {
        guard let contents = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        let fallbackDate = modificationDate(of: file)
        let sessionID = claudeSessionID(for: file)
        var currentCwd = cwdHint
        var eventsByID: [String: TokenUsageEvent] = [:]

        for line in contents.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let record = object as? [String: Any] else {
                continue
            }

            if let cwd = record["cwd"] as? String, !cwd.isEmpty {
                currentCwd = cwd
            }
            guard record["type"] as? String == "assistant",
                  let message = record["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any],
                  integerOptional(usage["output_tokens"]) != nil else {
                continue
            }

            let output = integer(usage["output_tokens"])
            let input = integer(usage["input_tokens"])
            let cacheRead = integer(usage["cache_read_input_tokens"])
            let cacheCreation = integer(usage["cache_creation_input_tokens"])
            let cacheCreationDetails = usage["cache_creation"] as? [String: Any]
            let write5m = integer(cacheCreationDetails?["ephemeral_5m_input_tokens"])
            let write1h = integer(cacheCreationDetails?["ephemeral_1h_input_tokens"])
            let effectiveWrite5m = write5m > 0 || write1h > 0 ? write5m : cacheCreation
            let date = parseDate(record["timestamp"]) ?? fallbackDate
            let model = message["model"] as? String
            let usageID = (message["id"] as? String)
                ?? (record["uuid"] as? String)
                ?? "(file.lastPathComponent):(lineNumber)"
            let toolCount = toolUseCount(message["content"])
            let tokenUsage = TokenUsage(
                inputTokens: input + cacheCreation + cacheRead,
                cacheReadTokens: cacheRead,
                cacheWrite5mTokens: effectiveWrite5m,
                cacheWrite1hTokens: write1h,
                outputTokens: output
            )

            eventsByID[usageID] = TokenUsageEvent(
                id: "claude:\(sessionID):\(usageID)",
                sessionID: sessionID,
                provider: .claude,
                model: model,
                cwd: normalizedPath(currentCwd),
                date: date,
                usage: tokenUsage,
                actions: toolCount
            )
        }

        return eventsByID.values.sorted { $0.date < $1.date }
    }

    private func claudeSessionID(for file: URL) -> String {
        let components = file.pathComponents
        if let subagentsIndex = components.lastIndex(of: "subagents"), subagentsIndex > 0 {
            return components[subagentsIndex - 1]
        }
        return file.deletingPathExtension().lastPathComponent
    }

    // MARK: - Codex

    private func scanCodex() -> [TokenUsageEvent] {
        let root = homeDirectory.appendingPathComponent(".codex/sessions", isDirectory: true)
        var result: [TokenUsageEvent] = []
        for file in jsonlFiles(in: root) {
            result.append(contentsOf: scanCodexSession(file))
        }
        return result
    }

    private func scanCodexSession(_ file: URL) -> [TokenUsageEvent] {
        guard let contents = try? String(contentsOf: file, encoding: .utf8),
              let firstLine = contents.split(separator: "\n", omittingEmptySubsequences: true).first,
              let firstData = String(firstLine).data(using: .utf8),
              let firstObject = try? JSONSerialization.jsonObject(with: firstData),
              let metadata = firstObject as? [String: Any],
              metadata["type"] as? String == "session_meta",
              let metadataPayload = metadata["payload"] as? [String: Any],
              let cwd = normalizedPath(metadataPayload["cwd"] as? String),
              !cwd.isEmpty else {
            return []
        }

        let sessionID = (metadataPayload["id"] as? String)
            ?? (metadataPayload["session_id"] as? String)
            ?? file.deletingPathExtension().lastPathComponent
        let fallbackDate = parseDate(metadata["timestamp"]) ?? modificationDate(of: file)
        var previous: TokenUsage?
        var currentModel: String?
        var events: [TokenUsageEvent] = []
        var lineNumber = 0

        for line in contents.split(separator: "\n", omittingEmptySubsequences: true) {
            defer { lineNumber += 1 }
            guard let data = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let record = object as? [String: Any],
                  let payload = record["payload"] as? [String: Any] else {
                continue
            }

            if let model = payload["model"] as? String, !model.isEmpty {
                currentModel = model
            } else if let info = payload["info"] as? [String: Any],
                      let model = info["model"] as? String,
                      !model.isEmpty {
                currentModel = model
            }

            guard payload["type"] as? String == "token_count",
                  let info = payload["info"] as? [String: Any],
                  let totals = info["total_token_usage"] as? [String: Any] else {
                continue
            }

            let current = TokenUsage(
                inputTokens: integer(totals["input_tokens"]),
                cacheReadTokens: integer(totals["cached_input_tokens"]),
                cacheWrite5mTokens: integer(totals["cache_write_input_tokens"] ?? totals["cache_creation_input_tokens"]),
                outputTokens: integer(totals["output_tokens"])
            )
            let delta = deltaUsage(current, previous: previous)
            previous = current
            guard delta.totalTokens > 0 else { continue }

            events.append(TokenUsageEvent(
                id: "codex:\(sessionID):\(lineNumber)",
                sessionID: sessionID,
                provider: .codex,
                model: currentModel,
                cwd: cwd,
                date: parseDate(record["timestamp"]) ?? fallbackDate,
                usage: delta
            ))
        }
        return events
    }

    private func deltaUsage(_ current: TokenUsage, previous: TokenUsage?) -> TokenUsage {
        guard let previous else { return current }
        return TokenUsage(
            inputTokens: nonNegativeDelta(current.inputTokens, previous.inputTokens),
            cacheReadTokens: nonNegativeDelta(current.cacheReadTokens, previous.cacheReadTokens),
            cacheWrite5mTokens: nonNegativeDelta(current.cacheWrite5mTokens, previous.cacheWrite5mTokens),
            cacheWrite1hTokens: nonNegativeDelta(current.cacheWrite1hTokens, previous.cacheWrite1hTokens),
            outputTokens: nonNegativeDelta(current.outputTokens, previous.outputTokens)
        )
    }

    // MARK: - Kimi Code

    private func scanKimi() -> [TokenUsageEvent] {
        let index = homeDirectory.appendingPathComponent(".kimi-code/session_index.jsonl")
        guard let contents = try? String(contentsOf: index, encoding: .utf8) else { return [] }
        var sessionDirectories: [URL] = []
        var seen: Set<String> = []

        for line in contents.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let record = object as? [String: Any],
                  let path = record["sessionDir"] as? String,
                  !path.isEmpty else { continue }
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: url.path), seen.insert(url.path).inserted {
                sessionDirectories.append(url)
            }
        }

        var result: [TokenUsageEvent] = []
        for directory in sessionDirectories {
            let agentsDirectory = directory.appendingPathComponent("agents", isDirectory: true)
            guard let agentDirectories = try? FileManager.default.contentsOfDirectory(
                at: agentsDirectory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for agentDirectory in agentDirectories where isDirectory(agentDirectory) {
                let wire = agentDirectory.appendingPathComponent("wire.jsonl")
                result.append(contentsOf: scanKimiWire(
                    wire,
                    cwd: normalizedPathFromIndex(directory: directory, index: index),
                    sessionID: directory.lastPathComponent + ":" + agentDirectory.lastPathComponent
                ))
            }
        }
        return result
    }

    private func normalizedPathFromIndex(directory: URL, index: URL) -> String? {
        // The index record is read again here only for the matching session.
        // This keeps the wire parser independent of the index's field names.
        guard let contents = try? String(contentsOf: index, encoding: .utf8) else { return nil }
        for line in contents.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let record = object as? [String: Any],
                  let path = record["sessionDir"] as? String,
                  URL(fileURLWithPath: path).path == directory.path else { continue }
            return normalizedPath(record["workDir"] as? String)
        }
        return nil
    }

    private func scanKimiWire(_ file: URL, cwd: String?, sessionID: String) -> [TokenUsageEvent] {
        guard let contents = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        var currentModel: String?
        var events: [TokenUsageEvent] = []
        var lineNumber = 0
        for line in contents.split(separator: "\n", omittingEmptySubsequences: true) {
            defer { lineNumber += 1 }
            guard let data = String(line).data(using: .utf8),
                  let record = try? JSONSerialization.jsonObject(with: data),
                  let object = record as? [String: Any] else { continue }
            let date = epochDate(object["time"], milliseconds: true) ?? modificationDate(of: file)
            let type = object["type"] as? String
            if type == "llm.request" {
                currentModel = (object["modelAlias"] as? String) ?? (object["model"] as? String)
            }
            guard type == "usage.record",
                  object["usageScope"] as? String == "turn",
                  let usage = object["usage"] as? [String: Any] else { continue }

            let cacheRead = integer(usage["inputCacheRead"])
            let cacheCreation = integer(usage["inputCacheCreation"])
            let otherInput = integer(usage["inputOther"])
            let output = integer(usage["output"])
            let tokenUsage = TokenUsage(
                inputTokens: otherInput + cacheRead + cacheCreation,
                cacheReadTokens: cacheRead,
                cacheWrite5mTokens: cacheCreation,
                outputTokens: output
            )
            guard tokenUsage.totalTokens > 0 else { continue }
            events.append(TokenUsageEvent(
                id: "kimi:\(sessionID):\(lineNumber)",
                sessionID: sessionID,
                provider: .kimi,
                model: currentModel,
                cwd: cwd,
                date: date,
                usage: tokenUsage
            ))
        }
        return events
    }

    // MARK: - Grok

    private func scanGrok() -> [TokenUsageEvent] {
        let root = homeDirectory.appendingPathComponent(".grok/sessions", isDirectory: true)
        guard let groups = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var result: [TokenUsageEvent] = []
        for group in groups where isDirectory(group) {
            let cwd = grokCWD(for: group)
            for file in jsonlFiles(in: group) where file.lastPathComponent == "updates.jsonl" {
                result.append(contentsOf: scanGrokUpdates(file, cwd: cwd))
            }
        }
        return result
    }

    private func grokCWD(for group: URL) -> String? {
        let cwdFile = group.appendingPathComponent(".cwd")
        if let contents = try? String(contentsOf: cwdFile, encoding: .utf8), !contents.isEmpty {
            return normalizedPath(contents.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return normalizedPath(group.lastPathComponent.removingPercentEncoding)
    }

    private func scanGrokUpdates(_ file: URL, cwd: String?) -> [TokenUsageEvent] {
        guard let contents = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        let session = file.deletingLastPathComponent()
        let sessionMeta = grokSessionMeta(at: session)
        let cwd = sessionMeta.cwd ?? cwd
        let fallbackDate = modificationDate(of: file)
        var records: [String: (total: Int64, date: Date, model: String?)] = [:]
        var lastSeenModel: String?
        var lineNumber = 0
        for line in contents.split(separator: "\n", omittingEmptySubsequences: true) {
            defer { lineNumber += 1 }
            guard let data = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let record = object as? [String: Any],
                  let params = record["params"] as? [String: Any] else {
                continue
            }

            if let lineModel = grokModel(fromParams: params) {
                lastSeenModel = lineModel
            }

            guard let metadata = params["_meta"] as? [String: Any],
                  let total = integerOptional(metadata["totalTokens"]),
                  total > 0 else {
                continue
            }
            let promptID = nonEmptyString(metadata["promptId"]) ?? "line-\(lineNumber)"
            let date = epochDate(metadata["agentTimestampMs"] ?? metadata["turnStartMs"], milliseconds: true)
                ?? fallbackDate
            let model = lastSeenModel ?? sessionMeta.model
            if let existing = records[promptID] {
                if existing.total > total {
                    if existing.model == nil, let model {
                        records[promptID] = (total: existing.total, date: existing.date, model: model)
                    }
                    continue
                }
                records[promptID] = (total: total, date: date, model: existing.model ?? model)
            } else {
                records[promptID] = (total: total, date: date, model: model)
            }
        }

        let sessionID = session.lastPathComponent
        return records.map { promptID, record in
            TokenUsageEvent(
                id: "grok:\(sessionID):\(promptID)",
                sessionID: sessionID,
                provider: .grok,
                model: record.model,
                cwd: cwd,
                date: record.date,
                usage: .totalOnly(record.total)
            )
        }.sorted { $0.date < $1.date }
    }

    private func grokModel(fromParams params: [String: Any]) -> String? {
        if let model = nonEmptyString(params["model"]) {
            return model
        }
        if let metadata = params["_meta"] as? [String: Any],
           let model = nonEmptyString(metadata["modelId"]) ?? nonEmptyString(metadata["model"]) {
            return model
        }
        guard let update = params["update"] as? [String: Any] else {
            return nil
        }
        if let updateMeta = update["_meta"] as? [String: Any],
           let model = nonEmptyString(updateMeta["modelId"]) ?? nonEmptyString(updateMeta["model"]) {
            return model
        }
        return nonEmptyString(update["model"])
    }

    private struct GrokSessionMeta {
        var cwd: String?
        var model: String?
    }

    private func grokSessionMeta(at session: URL) -> GrokSessionMeta {
        var meta = GrokSessionMeta()
        let summaryURL = session.appendingPathComponent("summary.json")
        if let data = try? Data(contentsOf: summaryURL),
           let object = try? JSONSerialization.jsonObject(with: data),
           let record = object as? [String: Any] {
            meta.model = nonEmptyString(record["current_model_id"])
            if let info = record["info"] as? [String: Any] {
                meta.cwd = normalizedPath(info["cwd"] as? String)
            }
        }
        if meta.model == nil {
            meta.model = grokLastEventModelID(
                at: session.appendingPathComponent("events.jsonl")
            )
        }
        return meta
    }

    private func grokLastEventModelID(at file: URL) -> String? {
        guard let contents = try? String(contentsOf: file, encoding: .utf8) else {
            return nil
        }
        var last: String?
        for line in contents.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let record = object as? [String: Any] else {
                continue
            }
            if let model = nonEmptyString(record["model_id"]) {
                last = model
                continue
            }
            for value in record.values {
                if let nested = value as? [String: Any],
                   let model = nonEmptyString(nested["model_id"]) {
                    last = model
                }
            }
        }
        return last
    }

    // MARK: - Cursor agent

    /// Cursor stores billed usage in two local places:
    ///
    /// 1. `~/.cursor/herdr-usage.jsonl` — one line per Cursor `stop` hook
    ///    (`afterAgentResponse` does not fire in Cursor CLI). Lines carry
    ///    the model id (e.g. `cursor-grok-4.6-high-fast` / `grok-4.6`)
    ///    and token counts. `stop` and `afterAgentResponse` report the
    ///    same `generation_id`; those lines are de-duplicated. This is how
    ///    Grok-backed Cursor sessions become visible: the chat store does
    ///    not persist xAI usage the way it persists Anthropic `usage`
    ///    objects.
    /// 2. `~/.cursor/chats/<project>/<session>/store.db` — Anthropic-shaped
    ///    `usage` JSON embedded in conversation blobs, plus `lastUsedModel`
    ///    and `cwd` from the session meta.
    private func scanCursor() -> [TokenUsageEvent] {
        var events: [TokenUsageEvent] = []
        events.append(contentsOf: scanCursorUsageLog())
        events.append(contentsOf: scanCursorChats())
        return events
    }

    private func scanCursorUsageLog() -> [TokenUsageEvent] {
        let file = homeDirectory.appendingPathComponent(".cursor/herdr-usage.jsonl")
        guard let contents = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        var eventsByID: [String: TokenUsageEvent] = [:]
        var lineNumber = 0
        for line in contents.split(separator: "\n", omittingEmptySubsequences: true) {
            defer { lineNumber += 1 }
            guard let data = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let record = object as? [String: Any] else { continue }

            let usageObject = record["usage"] as? [String: Any]
            let input = cursorLogInteger(["input_tokens", "inputTokens"], record, usageObject)
            let output = cursorLogInteger(["output_tokens", "outputTokens"], record, usageObject)
            let cacheRead = cursorLogInteger(
                ["cache_read_tokens", "cacheReadTokens", "cache_read_input_tokens"],
                record,
                usageObject
            )
            let cacheWrite = cursorLogInteger(
                ["cache_write_tokens", "cacheWriteTokens", "cache_creation_input_tokens"],
                record,
                usageObject
            )
            // Cursor's raw `inputTokens` already includes cache. Treat the
            // logged input as billed input and keep cache splits for pricing.
            let billedInput = max(input, cacheRead + cacheWrite)
            let tokenUsage = TokenUsage(
                inputTokens: billedInput,
                cacheReadTokens: cacheRead,
                cacheWrite5mTokens: cacheWrite,
                outputTokens: output
            )
            guard tokenUsage.totalTokens > 0 else { continue }

            let sessionID = nonEmptyString(record["conversation_id"])
                ?? nonEmptyString(record["conversationId"])
                ?? "line-\(lineNumber)"
            let model = cursorLogModel(record, usageObject)
            let cwd = normalizedPath(record["cwd"] as? String)
            let date = epochDate(record["ts_ms"] ?? record["timestamp_ms"], milliseconds: true)
                ?? parseDate(record["ts"] ?? record["timestamp"])
                ?? modificationDate(of: file)
            let generationID = nonEmptyString(record["generation_id"])
                ?? nonEmptyString(record["generationId"])
            let eventID = generationID.map { "cursor-log:\(sessionID):\($0)" }
                ?? "cursor-log:\(sessionID):\(lineNumber)"
            let event = TokenUsageEvent(
                id: eventID,
                sessionID: sessionID,
                provider: .cursor,
                model: model,
                cwd: cwd,
                date: date,
                usage: tokenUsage
            )
            if let existing = eventsByID[eventID],
               tokenUsage.totalTokens < existing.usage.totalTokens {
                continue
            }
            eventsByID[eventID] = event
        }
        return eventsByID.values.sorted { $0.date < $1.date }
    }

    private func cursorLogInteger(
        _ keys: [String],
        _ record: [String: Any],
        _ usage: [String: Any]?
    ) -> Int64 {
        for key in keys {
            if let value = integerOptional(record[key]) { return value }
        }
        if let usage {
            for key in keys {
                if let value = integerOptional(usage[key]) { return value }
            }
        }
        return 0
    }

    private func cursorLogModel(_ record: [String: Any], _ usage: [String: Any]?) -> String? {
        for key in ["model", "model_id", "modelName", "modelId"] {
            if let model = nonEmptyString(record[key]) { return model }
        }
        if let usage {
            for key in ["model", "model_id", "modelName", "modelId"] {
                if let model = nonEmptyString(usage[key]) { return model }
            }
        }
        return nil
    }

    private func scanCursorChats() -> [TokenUsageEvent] {
        let root = homeDirectory.appendingPathComponent(".cursor/chats", isDirectory: true)
        guard let projects = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var events: [TokenUsageEvent] = []
        for project in projects where isDirectory(project) {
            guard let sessions = try? FileManager.default.contentsOfDirectory(
                at: project,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for session in sessions where isDirectory(session) {
                events.append(contentsOf: scanCursorSession(session))
            }
        }
        return events
    }

    private func scanCursorSession(_ session: URL) -> [TokenUsageEvent] {
        let sessionID = session.lastPathComponent
        let meta = cursorSessionMeta(at: session)
        let cwd = normalizedPath(meta.cwd)
        var model = meta.model
        var events: [TokenUsageEvent] = []

        let store = session.appendingPathComponent("store.db")
        guard FileManager.default.fileExists(atPath: store.path) else { return [] }

        var db: OpaquePointer?
        let openResult = sqlite3_open_v2(store.path, &db, SQLITE_OPEN_READONLY, nil)
        guard openResult == SQLITE_OK, let db else { return [] }
        defer { sqlite3_close(db) }

        if model == nil, let stored = cursorLastUsedModel(db) {
            model = stored
        }

        let sql = "SELECT id, data FROM blobs"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            return []
        }
        defer { sqlite3_finalize(stmt) }

        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let blobID = sqliteText(stmt, index: 0),
                  let bytes = sqliteBlob(stmt, index: 1) else { continue }
            // File-read blobs of this repo's tests contain the same Anthropic
            // `usage` shape as a real API response. Skip those so a Cursor
            // session that grepped TokenMeterTests cannot mint fake cost.
            if bytes.range(of: Data("TokenMeterTests".utf8)) != nil
                || bytes.range(of: Data("#expect".utf8)) != nil {
                continue
            }
            let blobModel = cursorModelName(in: bytes) ?? model
            for (index, usage) in cursorAPIUsageObjects(in: bytes).enumerated() {
                events.append(TokenUsageEvent(
                    id: "cursor-chat:\(sessionID):\(blobID):\(index)",
                    sessionID: sessionID,
                    provider: .cursor,
                    model: blobModel ?? model,
                    cwd: cwd,
                    date: meta.date,
                    usage: usage
                ))
            }
        }
        return events
    }

    private struct CursorSessionMeta {
        var cwd: String?
        var model: String?
        var date: Date
    }

    private func cursorSessionMeta(at session: URL) -> CursorSessionMeta {
        let fallback = modificationDate(of: session)
        let metaURL = session.appendingPathComponent("meta.json")
        guard let data = try? Data(contentsOf: metaURL),
              let object = try? JSONSerialization.jsonObject(with: data),
              let record = object as? [String: Any] else {
            return CursorSessionMeta(cwd: nil, model: nil, date: fallback)
        }
        let date = epochDate(record["updatedAtMs"] ?? record["createdAtMs"], milliseconds: true)
            ?? fallback
        return CursorSessionMeta(
            cwd: record["cwd"] as? String,
            model: record["lastUsedModel"] as? String,
            date: date
        )
    }

    private func cursorLastUsedModel(_ db: OpaquePointer) -> String? {
        let sql = "SELECT value FROM meta LIMIT 1"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            return nil
        }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW,
              let hex = sqliteText(stmt, index: 0),
              let decoded = dataFromHex(hex),
              let object = try? JSONSerialization.jsonObject(with: decoded),
              let record = object as? [String: Any],
              let model = record["lastUsedModel"] as? String,
              !model.isEmpty else {
            return nil
        }
        return model
    }

    /// Anthropic-shaped usage objects that sit next to `stop_reason` or
    /// `service_tier` — the API response, not a quoted fixture.
    private func cursorAPIUsageObjects(in data: Data) -> [TokenUsage] {
        guard let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1) else { return [] }
        var result: [TokenUsage] = []
        var searchStart = text.startIndex
        while let usageRange = text.range(of: "\"usage\"", range: searchStart..<text.endIndex) {
            let windowStart = text.index(usageRange.lowerBound, offsetBy: -80, limitedBy: text.startIndex)
                ?? text.startIndex
            let window = text[windowStart..<usageRange.lowerBound]
            let isAPIResponse = window.contains("stop_reason") || window.contains("service_tier")
            searchStart = usageRange.upperBound
            guard isAPIResponse,
                  let brace = text[usageRange.upperBound...].firstIndex(of: "{"),
                  let json = extractJSONObject(from: text, startingAt: brace),
                  let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)),
                  let usage = object as? [String: Any] else { continue }

            let input = integer(usage["input_tokens"])
            let output = integer(usage["output_tokens"])
            let cacheRead = integer(usage["cache_read_input_tokens"])
            let cacheCreation = integer(usage["cache_creation_input_tokens"])
            let cacheCreationDetails = usage["cache_creation"] as? [String: Any]
            let write5m = integer(cacheCreationDetails?["ephemeral_5m_input_tokens"])
            let write1h = integer(cacheCreationDetails?["ephemeral_1h_input_tokens"])
            let effectiveWrite5m = write5m > 0 || write1h > 0 ? write5m : cacheCreation
            let tokenUsage = TokenUsage(
                inputTokens: input + cacheCreation + cacheRead,
                cacheReadTokens: cacheRead,
                cacheWrite5mTokens: effectiveWrite5m,
                cacheWrite1hTokens: write1h,
                outputTokens: output
            )
            if tokenUsage.totalTokens > 0 {
                result.append(tokenUsage)
            }
        }
        return result
    }

    private func cursorModelName(in data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1) else { return nil }
        for marker in ["\"modelName\":\"", "\"lastUsedModel\":\""] {
            guard let start = text.range(of: marker) else { continue }
            let rest = text[start.upperBound...]
            guard let end = rest.firstIndex(of: "\"") else { continue }
            let model = String(rest[rest.startIndex..<end])
            if !model.isEmpty { return model }
        }
        return nil
    }

    private func extractJSONObject(from text: String, startingAt start: String.Index) -> String? {
        var depth = 0
        var index = start
        var inString = false
        var escaped = false
        while index < text.endIndex {
            let character = text[index]
            if inString {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
            } else if character == "\"" {
                inString = true
            } else if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 {
                    return String(text[start...index])
                }
            }
            index = text.index(after: index)
            if text.distance(from: start, to: index) > 8_000 { return nil }
        }
        return nil
    }

    private func sqliteBlob(_ stmt: OpaquePointer, index: Int32) -> Data? {
        guard let bytes = sqlite3_column_blob(stmt, index) else { return nil }
        let length = Int(sqlite3_column_bytes(stmt, index))
        return Data(bytes: bytes, count: length)
    }

    private func dataFromHex(_ hex: String) -> Data? {
        let cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count.isMultiple(of: 2), !cleaned.isEmpty else { return nil }
        var data = Data(capacity: cleaned.count / 2)
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2)
            guard let byte = UInt8(cleaned[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }

    // MARK: - Helpers

    /// Maps an opencode DB model id to a TokenMeter provider for grouping.
    ///
    /// DeepSeek ids start with "deepseek"; Qwen / Alibaba and GLM ids start
    /// with "qwen"/"glm". Everything else (tencent/hy3:free, local LM Studio
    /// models, OpenRouter gateways) is grouped under Qwen / Alibaba as an
    /// "other gateway / local" bucket. Free and local models still price at
    /// $0 because the price book's unscoped model entries match regardless of
    /// provider, so this choice only affects the provider summary grouping.
    private static func provider(forOpenCodeModelID id: String) -> TokenMeterProvider {
        let lower = id.lowercased()
        if lower.hasPrefix("deepseek") { return .deepseek }
        if lower.hasPrefix("qwen") || lower.hasPrefix("glm") { return .qwen }
        return .qwen
    }

    // MARK: - OpenCode SQLite log

    private func scanOpenCode() -> [TokenUsageEvent] {
        let dbPath = homeDirectory
            .appendingPathComponent(".local/share/opencode/opencode.db", isDirectory: false)
            .path
        guard FileManager.default.fileExists(atPath: dbPath) else { return [] }

        var db: OpaquePointer?
        let openResult = sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil)
        guard openResult == SQLITE_OK, let db else { return [] }
        defer { sqlite3_close(db) }

        let sql = """
        SELECT rowid, id, model, agent, directory, tokens_input, tokens_output, \
        tokens_cache_read, tokens_cache_write, tokens_reasoning, time_created \
        FROM session WHERE model IS NOT NULL AND model != ''
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            return []
        }
        defer { sqlite3_finalize(stmt) }

        var events: [TokenUsageEvent] = []

        // Column layout: 0=rowid, 1=id, 2=model, 3=agent, 4=directory,
        // 5..=token counts, 10=time_created.
        while sqlite3_step(stmt) == SQLITE_ROW {
            let rowID = sqlite3_column_int64(stmt, 0)
            guard let modelID = sqliteModelJSONID(stmt, index: 2),
                  let sessionID = sqliteText(stmt, index: 1),
                  !sessionID.isEmpty else { continue }

            let input = sqliteInteger(stmt, index: 5)
            let output = sqliteInteger(stmt, index: 6)
            let cacheRead = sqliteInteger(stmt, index: 7)
            let cacheWrite = sqliteInteger(stmt, index: 8)
            let reasoning = sqliteInteger(stmt, index: 9)
            let timeCreated = sqliteInteger(stmt, index: 10)

            let tokenUsage = TokenUsage(
                inputTokens: input + cacheWrite + cacheRead,
                cacheReadTokens: cacheRead,
                cacheWrite5mTokens: cacheWrite,
                cacheWrite1hTokens: 0,
                outputTokens: output + reasoning
            )
            guard tokenUsage.totalTokens > 0 else { continue }

            let date = Date(timeIntervalSince1970: Double(timeCreated) / 1_000.0)
            let cwd = normalizedPath(sqliteText(stmt, index: 4))
            events.append(TokenUsageEvent(
                id: "opencode:\(sessionID):\(rowID)",
                sessionID: sessionID,
                provider: Self.provider(forOpenCodeModelID: modelID),
                model: modelID,
                cwd: cwd,
                date: date,
                usage: tokenUsage
            ))
        }
        return events
    }

    private func sqliteInteger(_ stmt: OpaquePointer, index: Int32) -> Int64 {
        sqlite3_column_int64(stmt, index)
    }

    private func sqliteText(_ stmt: OpaquePointer, index: Int32) -> String? {
        guard let cString = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: cString)
    }

    /// Parses the `model` column, which is a JSON object like
    /// `{"id":"deepseek-v4-flash-0731","providerID":"alibaba-token-plan"}`.
    /// Returns the `id` value if present, otherwise nil (row skipped).
    private func sqliteModelJSONID(_ stmt: OpaquePointer, index: Int32) -> String? {
        guard let text = sqliteText(stmt, index: index),
              let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any],
              let id = dict["id"] as? String,
              !id.isEmpty else { return nil }
        return id
    }

    // MARK: - File and JSON helpers

    private func jsonlFiles(in root: URL) -> [URL] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []
        ) else { return [] }
        var result: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" && isRegularFile(url) {
            result.append(url)
        }
        return result.sorted { $0.path < $1.path }
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private func isRegularFile(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }

    private func modificationDate(of url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            ?? .distantPast
    }

    private func parseDate(_ value: Any?) -> Date? {
        if let string = value as? String {
            return iso8601Formatter.date(from: string)
                ?? ISO8601DateFormatter().date(from: string)
        }
        return epochDate(value, milliseconds: false)
    }

    private func epochDate(_ value: Any?, milliseconds: Bool) -> Date? {
        guard let value = integerOptional(value), value > 0 else { return nil }
        let seconds = milliseconds ? Double(value) / 1_000.0 : Double(value)
        return Date(timeIntervalSince1970: seconds)
    }

    private func integer(_ value: Any?) -> Int64 {
        integerOptional(value) ?? 0
    }

    private func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func integerOptional(_ value: Any?) -> Int64? {
        if let value = value as? Int64 { return value }
        if let value = value as? Int { return Int64(value) }
        if let value = value as? Double { return Int64(value) }
        if let value = value as? NSNumber { return value.int64Value }
        if let value = value as? String { return Int64(value) }
        return nil
    }

    private func toolUseCount(_ value: Any?) -> Int {
        guard let blocks = value as? [[String: Any]] else { return 0 }
        return blocks.reduce(into: 0) { count, block in
            if block["type"] as? String == "tool_use" { count += 1 }
        }
    }

    private func nonNegativeDelta(_ current: Int64, _ previous: Int64) -> Int64 {
        current >= previous ? current - previous : current
    }

    private func normalizedPath(_ path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }

    private func claudeProjectKey(for cwd: String) -> String {
        cwd.replacingOccurrences(of: "[^A-Za-z0-9-]", with: "-", options: .regularExpression)
    }
}

// MARK: - Aggregation

private struct TokenMeterAccumulator {
    var usage = TokenUsage()
    var cost: Double = 0
    var pricedEvents = 0
    var hasUnpricedUsage = false
    var costIsEstimated = false
    var sessions: Set<String> = []
    var models: Set<String> = []
    var actions = 0

    mutating func add(_ event: TokenUsageEvent, priceBook: TokenMeterPriceBook) {
        usage.add(event.usage)
        sessions.insert("\(event.provider.rawValue):\(event.sessionID)")
        if let model = event.model, !model.isEmpty { models.insert(model) }
        actions += event.actions

        guard let pricing = priceBook.pricing(for: event.provider, model: event.model) else {
            hasUnpricedUsage = true
            return
        }
        cost += pricing.cost(for: event.usage)
        pricedEvents += 1
        costIsEstimated = costIsEstimated || !event.usage.isSplit || event.model == nil
    }

    func summary() -> TokenMeterSummary {
        TokenMeterSummary(
            usage: usage,
            costUSD: pricedEvents > 0 ? cost : nil,
            costIsEstimated: costIsEstimated,
            hasUnpricedUsage: hasUnpricedUsage,
            sessions: sessions.count,
            actions: actions,
            models: models.sorted()
        )
    }
}

private enum TokenMeterAggregator {
    static func snapshot(
        events: [TokenUsageEvent],
        agents: [Agent],
        priceBook: TokenMeterPriceBook,
        now: Date,
        calendar: Calendar
    ) -> TokenMeterSnapshot {
        let windows = UsageWindow.allCases
        var overall = makeAccumulatorMap(windows: windows)
        var providerAccumulators: [TokenMeterProvider: [UsageWindow: TokenMeterAccumulator]] = [:]
        var agentAccumulators: [AgentID: [UsageWindow: TokenMeterAccumulator]] = [:]
        var modelAccumulators: [String: [UsageWindow: TokenMeterAccumulator]] = [:]
        var ambiguous = 0

        for event in events where event.date <= now {
            let attribution = matchingAgent(for: event, agents: agents)
            if attribution.ambiguous { ambiguous += 1 }

            for window in windows where event.date >= window.startDate(now: now, calendar: calendar) {
                overall[window, default: TokenMeterAccumulator()].add(event, priceBook: priceBook)

                var providerMap = providerAccumulators[event.provider] ?? makeAccumulatorMap(windows: windows)
                providerMap[window, default: TokenMeterAccumulator()].add(event, priceBook: priceBook)
                providerAccumulators[event.provider] = providerMap

                if let model = event.model, !model.isEmpty {
                    var modelMap = modelAccumulators[model] ?? makeAccumulatorMap(windows: windows)
                    modelMap[window, default: TokenMeterAccumulator()].add(event, priceBook: priceBook)
                    modelAccumulators[model] = modelMap
                }

                if let agentID = attribution.agentID {
                    var agentMap = agentAccumulators[agentID] ?? makeAccumulatorMap(windows: windows)
                    agentMap[window, default: TokenMeterAccumulator()].add(event, priceBook: priceBook)
                    agentAccumulators[agentID] = agentMap
                }
            }
        }

        return TokenMeterSnapshot(
            generatedAt: now,
            overall: overall.mapValues { $0.summary() },
            providers: providerAccumulators.mapValues { $0.mapValues { $0.summary() } },
            agents: agentAccumulators.mapValues { $0.mapValues { $0.summary() } },
            models: modelAccumulators.mapValues { $0.mapValues { $0.summary() } },
            ambiguousAttributionCount: ambiguous
        )
    }

    private static func makeAccumulatorMap(
        windows: [UsageWindow]
    ) -> [UsageWindow: TokenMeterAccumulator] {
        Dictionary(uniqueKeysWithValues: windows.map { ($0, TokenMeterAccumulator()) })
    }

    private static func matchingAgent(
        for event: TokenUsageEvent,
        agents: [Agent]
    ) -> (agentID: AgentID?, ambiguous: Bool) {
        guard let eventCWD = event.cwd else {
            return (nil, false)
        }
        let matches = agents.filter { agent in
            if agent.kind == .opencode {
                // opencode is one CLI that can run deepseek/qwen/local models,
                // so it matches any priced event whose working directory
                // matches, regardless of the event's provider.
                return normalizedAgentCWD(agent.cwd) == eventCWD
            }
            return TokenMeterProvider(agentKind: agent.kind) == event.provider
                && normalizedAgentCWD(agent.cwd) == eventCWD
        }
        if matches.count == 1 { return (matches[0].id, false) }
        if matches.count > 1 { return (nil, true) }
        return (nil, false)
    }

    private static func normalizedAgentCWD(_ path: String) -> String? {
        guard !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }
}
