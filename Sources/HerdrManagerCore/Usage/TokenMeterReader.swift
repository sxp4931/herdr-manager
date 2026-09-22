import Foundation
import SQLite3

/// Reads the local session logs used by the supported coding-agent CLIs
/// and Cursor's local chat store / herdr-usage JSONL.
///
/// The actor owns all file I/O so a large transcript cannot block Shepherd's
/// menu-bar main actor. It never writes to, tails, or uploads the log files.
///
/// RAM / poll tradeoffs (intentional):
/// - JSONL is streamed in 64 KB chunks. Lines above `JSONLLineReader.maxLineBytes`
///   are drained and skipped so one transcript payload cannot pin RSS.
/// - Sidecar files (`summary.json`, `meta.json`, `.cwd`) are stat-capped
///   before read. Oversized stand-ins are ignored.
/// - Cursor chat blobs are filtered in SQL and again in Swift at
///   `BoundedFileRead.maxCursorBlobBytes`. Usage objects are extracted
///   from the SQLite column pointer without copying the blob into `Data`.
/// - Each file's events fold into window accumulators immediately. A scan
///   never concatenates every provider's files into one array.
/// - Cursor meta hex is capped at `BoundedFileRead.maxHexDecodedBytes`.
///   The SQLite TEXT column is refused above `maxHexEncodedBytes` before
///   it is copied into a Swift String.
/// - `fileEventCache` keeps parsed events for unchanged files so a 30s
///   menu-bar refresh does not re-read gigabyte logs. It is pruned to files
///   seen in the current scan. The All-time usage window needs those
///   historical events; dropping them would under-count.
/// - Claude, Codex, and Kimi logs are append-only. One that grew is read
///   from its last complete line with the parser state saved there, so a
///   live transcript costs only its new bytes per refresh. A log that
///   shrank, or whose 64 bytes before that point changed, is read from the
///   start. An edit further back in an otherwise growing log is not seen,
///   and a Claude message whose repeated usage lines straddle a read that
///   also crossed a week or month start can count twice. Grok, Cursor, and
///   opencode still re-read a changed file whole: Grok's events depend on
///   sidecars, the Cursor log is small, and SQLite is not append-only.
/// - Cached events older than every finite window are folded into one event
///   per (provider, session, model, cwd) by `TokenUsageCompaction`, so the
///   cache grows with sessions rather than with every logged turn. The
///   folded totals, sessions, models, attribution, and cost are unchanged;
///   `ambiguousAttributionCount` counts folded events once, which only
///   matters to callers that need more than "any ambiguity".
/// - Each refresh resolves a (provider, model) price and a (provider, cwd)
///   attribution once, not once per event and window: the price-book lookup
///   lowercases and sorts every entry, and cwd matching hits the filesystem.
public actor LocalTokenMeter {
    private let homeDirectory: URL
    private let iso8601Formatter: ISO8601DateFormatter
    /// Parsed usage events per file, and for append-only logs where the next
    /// read resumes. Avoids re-reading multi-gigabyte JSONL/SQLite logs
    /// every 30s.
    private var fileEventCache: [String: CachedFileEvents] = [:]
    private var seenCacheKeysThisScan: Set<String> = []
    /// Events before this date only count toward All-time in the current
    /// scan, so the cache may keep them folded.
    private var compactionCutoff: Date = .distantPast
    /// Bytes of append-only logs the last snapshot read. Internal so tests
    /// can prove a refresh reads only what was appended.
    private(set) var lastSnapshotLogBytesRead: UInt64 = 0

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

        seenCacheKeysThisScan.removeAll(keepingCapacity: true)
        lastSnapshotLogBytesRead = 0
        compactionCutoff = TokenUsageCompaction.cutoff(now: now, calendar: calendar)
        // Fold each file into the window accumulators so a 30s refresh never
        // concatenates every cached event into a second all-provider array.
        // `fileEventCache` still retains per-file events so the All-time
        // window and cwd re-attribution stay correct.
        var aggregator = TokenMeterAggregator(
            agents: agents,
            priceBook: priceBook,
            now: now,
            calendar: calendar
        )
        scanClaude(cwdHints: cwdHints, into: &aggregator)
        scanCodex(into: &aggregator)
        scanKimi(into: &aggregator)
        scanGrok(into: &aggregator)
        scanCursor(into: &aggregator)
        scanOpenCode(into: &aggregator)
        fileEventCache = fileEventCache.filter { seenCacheKeysThisScan.contains($0.key) }

        return aggregator.snapshot()
    }

    // MARK: - Claude Code

    private func scanClaude(cwdHints: [String: String], into aggregator: inout TokenMeterAggregator) {
        let root = homeDirectory.appendingPathComponent(".claude/projects", isDirectory: true)
        guard let projectDirectories = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        for project in projectDirectories where isDirectory(project) {
            let projectHint = cwdHints[project.lastPathComponent]
            for file in jsonlFiles(in: project) {
                aggregator.add(scanClaudeTranscript(file, cwdHint: projectHint))
            }
        }
    }

    private func scanClaudeTranscript(_ file: URL, cwdHint: String?) -> [TokenUsageEvent] {
        let sessionID = claudeSessionID(for: file)
        return appendOnlyLogEvents(
            for: file,
            extra: cwdHint ?? "",
            initialState: ClaudeTranscriptState(rawCwd: cwdHint, cwd: normalizedPath(cwdHint))
        ) { state, lineNumber, data in
            let looksLikeUsage = dataContains(data, "\"assistant\"") && dataContains(data, "\"usage\"")
            let looksLikeCwd = dataContains(data, "\"cwd\"") && data.count <= 65_536
            guard looksLikeUsage || looksLikeCwd else { return nil }

            guard let record = jsonObject(from: data) else { return nil }

            // Resolved once per change, not once per usage line: the
            // symlink walk hits the filesystem.
            if let cwd = record["cwd"] as? String, !cwd.isEmpty, cwd != state.rawCwd {
                state.rawCwd = cwd
                state.cwd = normalizedPath(cwd)
            }
            guard looksLikeUsage,
                  record["type"] as? String == "assistant",
                  let message = record["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any],
                  integerOptional(usage["output_tokens"]) != nil else {
                return nil
            }

            let output = integer(usage["output_tokens"])
            let input = integer(usage["input_tokens"])
            let cacheRead = integer(usage["cache_read_input_tokens"])
            let cacheCreation = integer(usage["cache_creation_input_tokens"])
            let cacheCreationDetails = usage["cache_creation"] as? [String: Any]
            let write5m = integer(cacheCreationDetails?["ephemeral_5m_input_tokens"])
            let write1h = integer(cacheCreationDetails?["ephemeral_1h_input_tokens"])
            let effectiveWrite5m = write5m > 0 || write1h > 0 ? write5m : cacheCreation
            let date = parseDate(record["timestamp"]) ?? modificationDate(of: file)
            let model = message["model"] as? String
            let usageID = (message["id"] as? String)
                ?? (record["uuid"] as? String)
                ?? "\(file.lastPathComponent):\(lineNumber)"
            let toolCount = toolUseCount(message["content"])
            let tokenUsage = TokenUsage(
                inputTokens: input + cacheCreation + cacheRead,
                cacheReadTokens: cacheRead,
                cacheWrite5mTokens: effectiveWrite5m,
                cacheWrite1hTokens: write1h,
                outputTokens: output
            )

            // Claude repeats a message's usage on each of its content
            // lines. The shared id makes the last one replace the others.
            return TokenUsageEvent(
                id: "claude:\(sessionID):\(usageID)",
                sessionID: sessionID,
                provider: .claude,
                model: model,
                cwd: state.cwd,
                date: date,
                usage: tokenUsage,
                actions: toolCount
            )
        }
    }

    private func claudeSessionID(for file: URL) -> String {
        let components = file.pathComponents
        if let subagentsIndex = components.lastIndex(of: "subagents"), subagentsIndex > 0 {
            return components[subagentsIndex - 1]
        }
        return file.deletingPathExtension().lastPathComponent
    }

    // MARK: - Codex

    private func scanCodex(into aggregator: inout TokenMeterAggregator) {
        let root = homeDirectory.appendingPathComponent(".codex/sessions", isDirectory: true)
        for file in jsonlFiles(in: root) {
            aggregator.add(scanCodexSession(file))
        }
    }

    private func scanCodexSession(_ file: URL) -> [TokenUsageEvent] {
        appendOnlyLogEvents(for: file, initialState: CodexSessionState()) { state, lineNumber, data in
            if !state.sawFirstLine {
                state.sawFirstLine = true
                guard let metadata = jsonObject(from: data),
                      metadata["type"] as? String == "session_meta",
                      let metadataPayload = metadata["payload"] as? [String: Any],
                      let parsedCwd = normalizedPath(metadataPayload["cwd"] as? String),
                      !parsedCwd.isEmpty else {
                    return nil
                }
                state.accepted = true
                state.cwd = parsedCwd
                state.sessionID = (metadataPayload["id"] as? String)
                    ?? (metadataPayload["session_id"] as? String)
                    ?? file.deletingPathExtension().lastPathComponent
                state.metaDate = parseDate(metadata["timestamp"])
                return nil
            }
            guard state.accepted else { return nil }

            guard dataContains(data, "token_count")
                    || dataContains(data, "\"model\"") else { return nil }
            guard let record = jsonObject(from: data),
                  let payload = record["payload"] as? [String: Any] else {
                return nil
            }

            if let model = payload["model"] as? String, !model.isEmpty {
                state.currentModel = model
            } else if let info = payload["info"] as? [String: Any],
                      let model = info["model"] as? String,
                      !model.isEmpty {
                state.currentModel = model
            }

            guard payload["type"] as? String == "token_count",
                  let info = payload["info"] as? [String: Any],
                  let totals = info["total_token_usage"] as? [String: Any] else {
                return nil
            }

            let current = TokenUsage(
                inputTokens: integer(totals["input_tokens"]),
                cacheReadTokens: integer(totals["cached_input_tokens"]),
                cacheWrite5mTokens: integer(totals["cache_write_input_tokens"] ?? totals["cache_creation_input_tokens"]),
                outputTokens: integer(totals["output_tokens"])
            )
            let delta = deltaUsage(current, previous: state.previous)
            state.previous = current
            guard delta.totalTokens > 0, let sessionID = state.sessionID, let cwd = state.cwd else {
                return nil
            }

            return TokenUsageEvent(
                id: "codex:\(sessionID):\(lineNumber)",
                sessionID: sessionID,
                provider: .codex,
                model: state.currentModel,
                cwd: cwd,
                date: parseDate(record["timestamp"]) ?? state.metaDate ?? modificationDate(of: file),
                usage: delta
            )
        }
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

    private func scanKimi(into aggregator: inout TokenMeterAggregator) {
        let index = homeDirectory.appendingPathComponent(".kimi-code/session_index.jsonl")
        var sessions: [(directory: URL, workDir: String?)] = []
        var seen: Set<String> = []

        JSONLLineReader.forEachLine(in: index) { _, data in
            guard let record = jsonObject(from: data),
                  let path = record["sessionDir"] as? String,
                  !path.isEmpty else { return }
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: url.path),
                  seen.insert(url.path).inserted else { return }
            sessions.append((directory: url, workDir: normalizedPath(record["workDir"] as? String)))
        }

        for session in sessions {
            let agentsDirectory = session.directory.appendingPathComponent("agents", isDirectory: true)
            guard let agentDirectories = try? FileManager.default.contentsOfDirectory(
                at: agentsDirectory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for agentDirectory in agentDirectories where isDirectory(agentDirectory) {
                let wire = agentDirectory.appendingPathComponent("wire.jsonl")
                aggregator.add(scanKimiWire(
                    wire,
                    cwd: session.workDir,
                    sessionID: session.directory.lastPathComponent + ":" + agentDirectory.lastPathComponent
                ))
            }
        }
    }

    private func scanKimiWire(_ file: URL, cwd: String?, sessionID: String) -> [TokenUsageEvent] {
        appendOnlyLogEvents(
            for: file,
            extra: cwd ?? "",
            initialState: KimiWireState()
        ) { state, lineNumber, data in
            guard dataContains(data, "llm.request")
                    || dataContains(data, "usage.record") else { return nil }
            guard let object = jsonObject(from: data) else { return nil }
            let type = object["type"] as? String
            if type == "llm.request" {
                state.currentModel = (object["modelAlias"] as? String) ?? (object["model"] as? String)
            }
            guard type == "usage.record",
                  object["usageScope"] as? String == "turn",
                  let usage = object["usage"] as? [String: Any] else { return nil }

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
            guard tokenUsage.totalTokens > 0 else { return nil }
            return TokenUsageEvent(
                id: "kimi:\(sessionID):\(lineNumber)",
                sessionID: sessionID,
                provider: .kimi,
                model: state.currentModel,
                cwd: cwd,
                date: epochDate(object["time"], milliseconds: true) ?? modificationDate(of: file),
                usage: tokenUsage
            )
        }
    }

    // MARK: - Grok

    private func scanGrok(into aggregator: inout TokenMeterAggregator) {
        let root = homeDirectory.appendingPathComponent(".grok/sessions", isDirectory: true)
        guard let groups = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for group in groups where isDirectory(group) {
            let cwd = grokCWD(for: group)
            guard let sessions = try? FileManager.default.contentsOfDirectory(
                at: group,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for session in sessions where isDirectory(session) {
                let file = session.appendingPathComponent("updates.jsonl")
                guard FileManager.default.fileExists(atPath: file.path) else { continue }
                let extra = [
                    cwd ?? "",
                    fileFingerprint(of: session.appendingPathComponent("summary.json"))
                        .map { "\($0.size):\($0.modification)" } ?? "",
                    fileFingerprint(of: session.appendingPathComponent("events.jsonl"))
                        .map { "\($0.size):\($0.modification)" } ?? "",
                ].joined(separator: "|")
                aggregator.add(cachedEvents(for: file, extra: extra) {
                    scanGrokUpdates(file, cwd: cwd)
                })
            }
        }
    }

    private func grokCWD(for group: URL) -> String? {
        let cwdFile = group.appendingPathComponent(".cwd")
        if let contents = BoundedFileRead.text(
            from: cwdFile,
            maxBytes: BoundedFileRead.maxPathFileBytes
        ), !contents.isEmpty {
            return normalizedPath(contents.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return normalizedPath(group.lastPathComponent.removingPercentEncoding)
    }

    private func scanGrokUpdates(_ file: URL, cwd: String?) -> [TokenUsageEvent] {
        let session = file.deletingLastPathComponent()
        let sessionMeta = grokSessionMeta(at: session)
        let cwd = sessionMeta.cwd ?? cwd
        let fallbackDate = modificationDate(of: file)
        var records: [String: (total: Int64, date: Date, model: String?)] = [:]
        var lastSeenModel: String?
        JSONLLineReader.forEachLine(in: file) { lineNumber, data in
            guard dataContains(data, "totalTokens")
                    || dataContains(data, "\"model\"")
                    || dataContains(data, "modelId") else { return }
            guard let record = jsonObject(from: data),
                  let params = record["params"] as? [String: Any] else {
                return
            }

            if let lineModel = grokModel(fromParams: params) {
                lastSeenModel = lineModel
            }

            guard let metadata = params["_meta"] as? [String: Any],
                  let total = integerOptional(metadata["totalTokens"]),
                  total > 0 else {
                return
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
                    return
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
        if let data = BoundedFileRead.data(
            from: summaryURL,
            maxBytes: BoundedFileRead.maxSidecarBytes
        ),
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
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size > 0 else { return nil }
        let window = min(size, 65_536)
        do {
            try handle.seek(toOffset: size - window)
            guard let data = try handle.read(upToCount: Int(window)), !data.isEmpty else {
                return nil
            }
            var slice = data
            if size > window, let newline = data.firstIndex(of: 0x0A), newline + 1 < data.endIndex {
                slice = data[(newline + 1)...]
            }
            var last: String?
            var start = slice.startIndex
            while start < slice.endIndex {
                let end = slice[start...].firstIndex(of: 0x0A) ?? slice.endIndex
                let line = slice[start..<end]
                start = end < slice.endIndex ? slice.index(after: end) : slice.endIndex
                guard !line.isEmpty,
                      let record = jsonObject(from: Data(line)) else { continue }
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
        } catch {
            return nil
        }
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
    private func scanCursor(into aggregator: inout TokenMeterAggregator) {
        aggregator.add(scanCursorUsageLog())
        scanCursorChats(into: &aggregator)
    }

    private func scanCursorUsageLog() -> [TokenUsageEvent] {
        let file = homeDirectory.appendingPathComponent(".cursor/herdr-usage.jsonl")
        return cachedEvents(for: file) {
            scanCursorUsageLogUncached(file)
        }
    }

    private func scanCursorUsageLogUncached(_ file: URL) -> [TokenUsageEvent] {
        var eventsByID: [String: TokenUsageEvent] = [:]
        JSONLLineReader.forEachLine(in: file) { lineNumber, data in
            guard dataContains(data, "input_tokens")
                    || dataContains(data, "inputTokens")
                    || dataContains(data, "\"usage\"") else { return }
            guard let record = jsonObject(from: data) else { return }

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
            guard tokenUsage.totalTokens > 0 else { return }

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
                return
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

    private func scanCursorChats(into aggregator: inout TokenMeterAggregator) {
        let root = homeDirectory.appendingPathComponent(".cursor/chats", isDirectory: true)
        guard let projects = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for project in projects where isDirectory(project) {
            guard let sessions = try? FileManager.default.contentsOfDirectory(
                at: project,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for session in sessions where isDirectory(session) {
                let store = session.appendingPathComponent("store.db")
                let meta = session.appendingPathComponent("meta.json")
                let extra = fileFingerprint(of: meta).map { "\($0.size):\($0.modification)" } ?? ""
                aggregator.add(cachedEvents(for: store, extra: extra) {
                    scanCursorSession(session)
                })
            }
        }
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
        configureReadOnlySQLite(db)

        if model == nil, let stored = cursorLastUsedModel(db) {
            model = stored
        }

        let sql = "SELECT id, data FROM blobs WHERE length(data) <= \(BoundedFileRead.maxCursorBlobBytes)"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            return []
        }
        defer { sqlite3_finalize(stmt) }

        let usageMarker = Data("\"usage\"".utf8)
        let testMarker = Data("TokenMeterTests".utf8)
        let expectMarker = Data("#expect".utf8)
        while sqlite3_step(stmt) == SQLITE_ROW {
            autoreleasepool {
                let length = Int(sqlite3_column_bytes(stmt, 1))
                guard BoundedFileRead.sqliteColumnFits(
                    length,
                    maxBytes: BoundedFileRead.maxCursorBlobBytes
                ),
                      let blobID = sqliteText(stmt, index: 0),
                      let raw = sqlite3_column_blob(stmt, 1) else { return }
                let buffer = UnsafeRawBufferPointer(start: raw, count: length)
                // File-read blobs of this repo's tests contain the same Anthropic
                // `usage` shape as a real API response. Skip those so a Cursor
                // session that grepped TokenMeterTests cannot mint fake cost.
                if firstIndex(of: testMarker, in: buffer, from: 0) != nil
                    || firstIndex(of: expectMarker, in: buffer, from: 0) != nil {
                    return
                }
                guard firstIndex(of: usageMarker, in: buffer, from: 0) != nil else { return }
                let blobModel = cursorModelName(in: buffer) ?? model
                for (index, usage) in cursorAPIUsageObjects(in: buffer).enumerated() {
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
        guard let data = BoundedFileRead.data(
            from: metaURL,
            maxBytes: BoundedFileRead.maxSidecarBytes
        ),
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
              let hex = sqliteText(
                stmt,
                index: 0,
                maxBytes: BoundedFileRead.maxHexEncodedBytes
              ),
              let decoded = BoundedFileRead.dataFromHex(hex),
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
    ///
    /// Scans the SQLite column as a raw byte buffer and only copies the
    /// small object that follows `"usage"`. Copying a 2 MB chat blob into
    /// `Data` on every cache miss was a menu-bar RSS spike.
    private func cursorAPIUsageObjects(in buffer: UnsafeRawBufferPointer) -> [TokenUsage] {
        let usageMarker = Data("\"usage\"".utf8)
        let stopReason = Data("stop_reason".utf8)
        let serviceTier = Data("service_tier".utf8)
        var result: [TokenUsage] = []
        var searchStart = 0
        while let usageIndex = firstIndex(of: usageMarker, in: buffer, from: searchStart) {
            let windowStart = max(0, usageIndex - 80)
            let isAPIResponse = firstIndex(
                of: stopReason, in: buffer, from: windowStart, to: usageIndex
            ) != nil
                || firstIndex(
                    of: serviceTier, in: buffer, from: windowStart, to: usageIndex
                ) != nil
            searchStart = usageIndex + usageMarker.count
            guard isAPIResponse,
                  let brace = firstIndex(of: 0x7B, in: buffer, from: searchStart),
                  let json = extractJSONObjectData(from: buffer, startingAt: brace),
                  let object = try? JSONSerialization.jsonObject(with: json),
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

    private func cursorModelName(in buffer: UnsafeRawBufferPointer) -> String? {
        let markers = [
            Data("\"modelName\":\"".utf8),
            Data("\"lastUsedModel\":\"".utf8),
        ]
        for marker in markers {
            guard let start = firstIndex(of: marker, in: buffer, from: 0) else { continue }
            let restStart = start + marker.count
            guard let end = firstIndex(of: 0x22, in: buffer, from: restStart) else { continue }
            let count = end - restStart
            guard count > 0, count <= 200,
                  let base = buffer.baseAddress else { continue }
            let modelData = Data(bytes: base.advanced(by: restStart), count: count)
            guard let model = String(data: modelData, encoding: .utf8),
                  !model.isEmpty else { continue }
            return model
        }
        return nil
    }

    /// Brace-matched JSON object starting at `{`, capped so a huge blob cannot
    /// pin a 2 MB decode of surrounding chat text.
    private func extractJSONObjectData(
        from buffer: UnsafeRawBufferPointer,
        startingAt start: Int
    ) -> Data? {
        var depth = 0
        var index = start
        var inString = false
        var escaped = false
        while index < buffer.count {
            if index - start > 8_000 { return nil }
            let byte = buffer[index]
            if inString {
                if escaped {
                    escaped = false
                } else if byte == 0x5C {
                    escaped = true
                } else if byte == 0x22 {
                    inString = false
                }
            } else if byte == 0x22 {
                inString = true
            } else if byte == 0x7B {
                depth += 1
            } else if byte == 0x7D {
                depth -= 1
                if depth == 0 {
                    guard let base = buffer.baseAddress else { return nil }
                    return Data(bytes: base.advanced(by: start), count: index - start + 1)
                }
            }
            index += 1
        }
        return nil
    }

    private func firstIndex(
        of needle: Data,
        in buffer: UnsafeRawBufferPointer,
        from start: Int,
        to endExclusive: Int? = nil
    ) -> Int? {
        guard !needle.isEmpty else { return nil }
        let needleCount = needle.count
        let bound = min(endExclusive ?? buffer.count, buffer.count)
        let lastStart = bound - needleCount
        guard start >= 0, start <= lastStart else { return nil }
        return needle.withUnsafeBytes { needleRaw in
            let needleBytes = needleRaw.bindMemory(to: UInt8.self)
            var i = start
            while i <= lastStart {
                var matched = true
                for j in 0..<needleCount {
                    if buffer[i + j] != needleBytes[j] {
                        matched = false
                        break
                    }
                }
                if matched { return i }
                i += 1
            }
            return nil
        }
    }

    private func firstIndex(
        of byte: UInt8,
        in buffer: UnsafeRawBufferPointer,
        from start: Int
    ) -> Int? {
        var i = start
        while i < buffer.count {
            if buffer[i] == byte { return i }
            i += 1
        }
        return nil
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

    private func scanOpenCode(into aggregator: inout TokenMeterAggregator) {
        let dbURL = homeDirectory
            .appendingPathComponent(".local/share/opencode/opencode.db", isDirectory: false)
        aggregator.add(cachedEvents(for: dbURL) {
            scanOpenCodeUncached(dbURL)
        })
    }

    private func scanOpenCodeUncached(_ dbURL: URL) -> [TokenUsageEvent] {
        let dbPath = dbURL.path
        guard FileManager.default.fileExists(atPath: dbPath) else { return [] }

        var db: OpaquePointer?
        let openResult = sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil)
        guard openResult == SQLITE_OK, let db else { return [] }
        defer { sqlite3_close(db) }
        configureReadOnlySQLite(db)

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

    private func sqliteText(
        _ stmt: OpaquePointer,
        index: Int32,
        maxBytes: Int = 64 * 1024
    ) -> String? {
        let length = Int(sqlite3_column_bytes(stmt, index))
        guard BoundedFileRead.sqliteColumnFits(length, maxBytes: maxBytes) else {
            return nil
        }
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

    // MARK: - Streaming / cache

    private func fileFingerprint(of url: URL) -> FileFingerprint? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = values.fileSize else {
            return nil
        }
        return FileFingerprint(
            size: Int64(size),
            modification: values.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0
        )
    }

    private func cachedEvents(
        for url: URL,
        extra: String = "",
        scan: () -> [TokenUsageEvent]
    ) -> [TokenUsageEvent] {
        let key = url.path
        seenCacheKeysThisScan.insert(key)
        guard let fingerprint = fileFingerprint(of: url) else {
            fileEventCache.removeValue(forKey: key)
            return []
        }
        if let cached = fileEventCache[key],
           cached.fingerprint == fingerprint,
           cached.extra == extra,
           cached.compactedBefore <= compactionCutoff {
            return unchangedEvents(key: key, cached)
        }
        // A cutoff that moved back (clock change, time zone, test `now`)
        // would need history that was already folded, so read the file again.
        let events = autoreleasepool {
            TokenUsageCompaction.compact(scan(), before: compactionCutoff)
        }
        fileEventCache[key] = CachedFileEvents(
            fingerprint: fingerprint,
            extra: extra,
            compactedBefore: compactionCutoff,
            events: events
        )
        return events
    }

    /// Cached events for a file that has not changed. The cutoff only moves
    /// forward with the clock; folding again keeps a long-lived cache from
    /// growing with each new month.
    private func unchangedEvents(key: String, _ cached: CachedFileEvents) -> [TokenUsageEvent] {
        guard cached.compactedBefore < compactionCutoff else { return cached.events }
        var refolded = cached
        refolded.events = TokenUsageCompaction.compact(
            cached.events,
            before: compactionCutoff,
            keeping: cached.resume?.tailEventID
        )
        refolded.compactedBefore = compactionCutoff
        fileEventCache[key] = refolded
        return refolded.events
    }

    /// Events for an append-only JSONL log. After the first read, a log that
    /// grew is read from where the last read stopped, with the parser state
    /// saved there, instead of from byte 0: a live transcript changes on
    /// every refresh, and re-reading it whole every 30s was the menu bar's
    /// steady I/O and JSON cost. A log that shrank, or whose bytes before
    /// the resume point changed, is read again from the start.
    ///
    /// - Parameters:
    ///   - initialState: Parser state at the start of the file.
    ///   - parse: Consumes one line. An event whose id matches an earlier
    ///     one replaces it, in this read and across reads.
    private func appendOnlyLogEvents<State>(
        for url: URL,
        extra: String = "",
        initialState: State,
        parse: (inout State, _ lineNumber: Int, _ line: Data) -> TokenUsageEvent?
    ) -> [TokenUsageEvent] {
        let key = url.path
        seenCacheKeysThisScan.insert(key)
        guard let fingerprint = fileFingerprint(of: url) else {
            fileEventCache.removeValue(forKey: key)
            return []
        }
        if let cached = fileEventCache[key],
           cached.extra == extra,
           cached.compactedBefore <= compactionCutoff {
            if cached.fingerprint == fingerprint {
                return unchangedEvents(key: key, cached)
            }
            if let resume = cached.resume,
               let state = resume.state as? State,
               UInt64(max(fingerprint.size, 0)) >= resume.point.offset,
               JSONLLineReader.signature(of: url, endingAt: resume.point.offset) == resume.signature,
               let appended = readAppendOnlyLog(url, from: resume.point, state: state, parse: parse) {
                return storeAppendOnlyEvents(
                    key: key,
                    fingerprint: fingerprint,
                    extra: extra,
                    events: TokenUsageEventLog.merging(cached.events, with: appended.events),
                    resume: appended.resume
                )
            }
        }
        guard let full = readAppendOnlyLog(url, from: .start, state: initialState, parse: parse) else {
            fileEventCache.removeValue(forKey: key)
            return []
        }
        return storeAppendOnlyEvents(
            key: key,
            fingerprint: fingerprint,
            extra: extra,
            events: full.events,
            resume: full.resume
        )
    }

    private func readAppendOnlyLog<State>(
        _ url: URL,
        from start: JSONLResumePoint,
        state initialState: State,
        parse: (inout State, _ lineNumber: Int, _ line: Data) -> TokenUsageEvent?
    ) -> (events: [TokenUsageEvent], resume: AppendOnlyResume)? {
        var state = initialState
        // The unterminated last line is read again next time, so the saved
        // state must not include it.
        var stateBeforeTail: State?
        var tailEventID: String?
        var parsed = TokenUsageEventLog()
        let read = autoreleasepool {
            JSONLLineReader.forEachLine(in: url, resumingAt: start) { lineNumber, line, terminated in
                if !terminated { stateBeforeTail = state }
                let event = parse(&state, lineNumber, line)
                if let event { parsed.add(event) }
                if !terminated { tailEventID = event?.id }
            }
        }
        guard let read,
              let signature = JSONLLineReader.signature(of: url, endingAt: read.resumePoint.offset) else {
            return nil
        }
        lastSnapshotLogBytesRead += read.bytesRead
        return (
            events: parsed.events,
            resume: AppendOnlyResume(
                point: read.resumePoint,
                signature: signature,
                state: stateBeforeTail ?? state,
                tailEventID: tailEventID
            )
        )
    }

    private func storeAppendOnlyEvents(
        key: String,
        fingerprint: FileFingerprint,
        extra: String,
        events: [TokenUsageEvent],
        resume: AppendOnlyResume
    ) -> [TokenUsageEvent] {
        let compacted = TokenUsageCompaction.compact(
            events,
            before: compactionCutoff,
            keeping: resume.tailEventID
        )
        fileEventCache[key] = CachedFileEvents(
            fingerprint: fingerprint,
            extra: extra,
            compactedBefore: compactionCutoff,
            events: compacted,
            resume: resume
        )
        return compacted
    }

    private func configureReadOnlySQLite(_ db: OpaquePointer) {
        sqlite3_exec(db, "PRAGMA query_only = 1;", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA cache_size = -2000;", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA mmap_size = 0;", nil, nil, nil)
    }

    private func dataContains(_ data: Data, _ ascii: String) -> Bool {
        data.range(of: Data(ascii.utf8)) != nil
    }

    private func jsonObject(from data: Data) -> [String: Any]? {
        guard !data.isEmpty else { return nil }
        return autoreleasepool {
            (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }
    }

}

private struct FileFingerprint: Equatable {
    var size: Int64
    var modification: TimeInterval
}

private struct CachedFileEvents {
    var fingerprint: FileFingerprint
    var extra: String
    /// `events` holds folded history for dates before this cutoff.
    var compactedBefore: Date
    var events: [TokenUsageEvent]
    /// Set for append-only logs, which a later refresh reads from here.
    var resume: AppendOnlyResume? = nil
}

private struct AppendOnlyResume {
    var point: JSONLResumePoint
    /// `JSONLLineReader.signature` at `point` when it was saved.
    var signature: Data
    /// The scanner's parser state at `point`, of the scanner's `State` type.
    var state: Any
    /// The event parsed from an unterminated last line. That line is read
    /// again and its event replaced by id, so it is never folded.
    var tailEventID: String?
}

private struct ClaudeTranscriptState {
    /// Last `cwd` seen, as logged and as resolved for attribution.
    var rawCwd: String?
    var cwd: String?
}

private struct CodexSessionState {
    var sawFirstLine = false
    /// Whether the first line was a `session_meta` with a cwd.
    var accepted = false
    var sessionID: String?
    var cwd: String?
    var metaDate: Date?
    /// Cumulative totals from the last `token_count`, for deltas.
    var previous: TokenUsage?
    var currentModel: String?
}

private struct KimiWireState {
    var currentModel: String?
}

/// Events from one read of a log, with a later event replacing an earlier
/// one that has the same id.
struct TokenUsageEventLog {
    private(set) var events: [TokenUsageEvent] = []
    private var indexByID: [String: Int] = [:]

    mutating func add(_ event: TokenUsageEvent) {
        if let index = indexByID[event.id] {
            events[index] = event
        } else {
            indexByID[event.id] = events.count
            events.append(event)
        }
    }

    /// `base` with each of `newer` replacing the event that has its id, or
    /// appended. Only ids in `newer` are indexed, so merging a few appended
    /// lines into a long cached history does not build a map of all of it.
    static func merging(_ base: [TokenUsageEvent], with newer: [TokenUsageEvent]) -> [TokenUsageEvent] {
        guard !newer.isEmpty else { return base }
        let newerIDs = Set(newer.map(\.id))
        var merged = base
        var indexByID: [String: Int] = [:]
        for index in merged.indices where newerIDs.contains(merged[index].id) {
            indexByID[merged[index].id] = index
        }
        for event in newer {
            if let index = indexByID[event.id] {
                merged[index] = event
            } else {
                indexByID[event.id] = merged.count
                merged.append(event)
            }
        }
        return merged
    }
}

// MARK: - History compaction

/// Folds usage events that can only land in the All-time window.
///
/// Events before `cutoff(now:calendar:)` are merged per (provider, session,
/// model, cwd, split/total-only). Everything the aggregator reads from them
/// is preserved: token sums, actions, the session and model sets, agent
/// attribution (provider + cwd), and pricing (provider + model). Cost is
/// linear in the token counts except where uncached input is clamped at
/// zero, so events that hit that clamp are never merged.
enum TokenUsageCompaction {
    /// The earliest start of the hour, day, week, and month windows.
    static func cutoff(now: Date, calendar: Calendar) -> Date {
        UsageWindow.allCases
            .filter { $0 != .allTime }
            .map { $0.startDate(now: now, calendar: calendar) }
            .min() ?? now
    }

    /// - Parameter keptID: An event that is never folded, because a later
    ///   read may replace it by id.
    static func compact(
        _ events: [TokenUsageEvent],
        before cutoff: Date,
        keeping keptID: String? = nil
    ) -> [TokenUsageEvent] {
        var kept: [TokenUsageEvent] = []
        var groups: [Key: Group] = [:]
        var order: [Key] = []

        for event in events {
            guard event.date < cutoff, isLinearlyPriced(event.usage), event.id != keptID else {
                kept.append(event)
                continue
            }
            let key = Key(
                provider: event.provider,
                sessionID: event.sessionID,
                model: event.model,
                cwd: event.cwd,
                isSplit: event.usage.isSplit
            )
            if groups[key] == nil {
                groups[key] = Group(first: event)
                order.append(key)
            } else {
                groups[key]?.add(event)
            }
        }

        // Nothing to fold: hand back the original array rather than a copy.
        guard groups.count < events.count - kept.count else { return events }

        kept.reserveCapacity(kept.count + order.count)
        for key in order {
            if let group = groups[key] {
                kept.append(group.event)
            }
        }
        return kept
    }

    /// Whether `TokenMeterPricing.cost(for:)` is linear for this usage, so a
    /// sum of such usages costs the same as the sum of their costs.
    private static func isLinearlyPriced(_ usage: TokenUsage) -> Bool {
        guard usage.isSplit else { return true }
        return usage.inputTokens
            >= usage.cacheReadTokens + usage.cacheWrite5mTokens + usage.cacheWrite1hTokens
    }

    private struct Key: Hashable {
        let provider: TokenMeterProvider
        let sessionID: String
        let model: String?
        let cwd: String?
        let isSplit: Bool
    }

    private struct Group {
        let first: TokenUsageEvent
        var usage: TokenUsage
        var actions: Int
        var latest: Date
        var count = 1

        init(first: TokenUsageEvent) {
            self.first = first
            self.usage = first.usage
            self.actions = first.actions
            self.latest = first.date
        }

        mutating func add(_ event: TokenUsageEvent) {
            usage.add(event.usage)
            actions += event.actions
            latest = max(latest, event.date)
            count += 1
        }

        var event: TokenUsageEvent {
            guard count > 1 else { return first }
            return TokenUsageEvent(
                id: "\(first.id)+\(count - 1)",
                sessionID: first.sessionID,
                provider: first.provider,
                model: first.model,
                cwd: first.cwd,
                date: latest,
                usage: usage,
                actions: actions
            )
        }
    }
}

// MARK: - Aggregation

struct TokenMeterAccumulator {
    var usage = TokenUsage()
    var cost: Double = 0
    var pricedEvents = 0
    var hasUnpricedUsage = false
    var costIsEstimated = false
    var sessions: Set<String> = []
    var models: Set<String> = []
    var actions = 0

    /// - Parameters:
    ///   - sessionKey: `provider:sessionID`, built once per event.
    ///   - eventCost: The event's priced cost, or nil when its model has no
    ///     price.
    mutating func add(_ event: TokenUsageEvent, sessionKey: String, cost eventCost: Double?) {
        usage.add(event.usage)
        sessions.insert(sessionKey)
        if let model = event.model, !model.isEmpty { models.insert(model) }
        actions += event.actions

        guard let eventCost else {
            hasUnpricedUsage = true
            return
        }
        cost += eventCost
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

/// Folds usage events into per-window accumulators for one refresh.
///
/// Everything that does not depend on the event is resolved once: window
/// start dates, agent cwds (symlink resolution), and, memoized per key,
/// the price for a (provider, model) and the agent for a (provider, cwd).
struct TokenMeterAggregator {
    let priceBook: TokenMeterPriceBook
    let now: Date
    private let windowStarts: [(window: UsageWindow, start: Date)]
    /// Every window, empty. Copied on first sight of a provider, model, or
    /// agent so each summary map lists all windows.
    private let emptyAccumulatorMap: [UsageWindow: TokenMeterAccumulator]
    private let candidates: [AgentCandidate]
    private var pricingCache: [PricingKey: TokenMeterPricing?] = [:]
    private var attributionCache: [AttributionKey: Attribution] = [:]
    var overall: [UsageWindow: TokenMeterAccumulator]
    var providerAccumulators: [TokenMeterProvider: [UsageWindow: TokenMeterAccumulator]] = [:]
    var agentAccumulators: [AgentID: [UsageWindow: TokenMeterAccumulator]] = [:]
    var modelAccumulators: [String: [UsageWindow: TokenMeterAccumulator]] = [:]
    var ambiguous = 0

    init(agents: [Agent], priceBook: TokenMeterPriceBook, now: Date, calendar: Calendar) {
        self.priceBook = priceBook
        self.now = now
        self.windowStarts = UsageWindow.allCases.map { window in
            (window: window, start: window.startDate(now: now, calendar: calendar))
        }
        self.candidates = agents.map { agent in
            AgentCandidate(
                id: agent.id,
                // opencode is one CLI that can run deepseek/qwen/local
                // models, so it matches any priced event whose working
                // directory matches, regardless of the event's provider.
                provider: agent.kind == .opencode ? nil : TokenMeterProvider(agentKind: agent.kind),
                matchesAnyProvider: agent.kind == .opencode,
                cwd: Self.normalizedAgentCWD(agent.cwd)
            )
        }
        let emptyMap = Dictionary(
            uniqueKeysWithValues: UsageWindow.allCases.map { ($0, TokenMeterAccumulator()) }
        )
        self.emptyAccumulatorMap = emptyMap
        self.overall = emptyMap
    }

    mutating func add(_ events: [TokenUsageEvent]) {
        for event in events {
            add(event)
        }
    }

    mutating func add(_ event: TokenUsageEvent) {
        guard event.date <= now else { return }
        let attribution = matchingAgent(for: event)
        if attribution.ambiguous { ambiguous += 1 }
        let sessionKey = "\(event.provider.rawValue):\(event.sessionID)"
        let cost = pricing(for: event).map { $0.cost(for: event.usage) }
        let model = event.model.flatMap { $0.isEmpty ? nil : $0 }
        // A local, so the `default:` autoclosures below do not capture self
        // while a nested map of self is being mutated.
        let emptyMap = emptyAccumulatorMap

        // Mutate the nested maps in place. Copying a map out and back in
        // duplicated every accumulator's session and model sets per event.
        for (window, start) in windowStarts where event.date >= start {
            overall[window, default: TokenMeterAccumulator()]
                .add(event, sessionKey: sessionKey, cost: cost)
            providerAccumulators[event.provider, default: emptyMap][
                window, default: TokenMeterAccumulator()
            ].add(event, sessionKey: sessionKey, cost: cost)

            if let model {
                modelAccumulators[model, default: emptyMap][
                    window, default: TokenMeterAccumulator()
                ].add(event, sessionKey: sessionKey, cost: cost)
            }

            if let agentID = attribution.agentID {
                agentAccumulators[agentID, default: emptyMap][
                    window, default: TokenMeterAccumulator()
                ].add(event, sessionKey: sessionKey, cost: cost)
            }
        }
    }

    func snapshot() -> TokenMeterSnapshot {
        TokenMeterSnapshot(
            generatedAt: now,
            overall: overall.mapValues { $0.summary() },
            providers: providerAccumulators.mapValues { $0.mapValues { $0.summary() } },
            agents: agentAccumulators.mapValues { $0.mapValues { $0.summary() } },
            models: modelAccumulators.mapValues { $0.mapValues { $0.summary() } },
            ambiguousAttributionCount: ambiguous
        )
    }

    private mutating func pricing(for event: TokenUsageEvent) -> TokenMeterPricing? {
        let key = PricingKey(provider: event.provider, model: event.model)
        if let cached = pricingCache[key] {
            return cached
        }
        let pricing = priceBook.pricing(for: event.provider, model: event.model)
        // `updateValue` stores a nil price too; assigning nil would remove it.
        pricingCache.updateValue(pricing, forKey: key)
        return pricing
    }

    private mutating func matchingAgent(for event: TokenUsageEvent) -> Attribution {
        guard let eventCWD = event.cwd else {
            return Attribution(agentID: nil, ambiguous: false)
        }
        let key = AttributionKey(provider: event.provider, cwd: eventCWD)
        if let cached = attributionCache[key] {
            return cached
        }
        let matches = candidates.filter { candidate in
            (candidate.matchesAnyProvider || candidate.provider == event.provider)
                && candidate.cwd == eventCWD
        }
        let attribution: Attribution
        if matches.count == 1 {
            attribution = Attribution(agentID: matches[0].id, ambiguous: false)
        } else {
            attribution = Attribution(agentID: nil, ambiguous: matches.count > 1)
        }
        attributionCache[key] = attribution
        return attribution
    }

    private static func normalizedAgentCWD(_ path: String) -> String? {
        guard !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }

    private struct AgentCandidate {
        let id: AgentID
        let provider: TokenMeterProvider?
        let matchesAnyProvider: Bool
        let cwd: String?
    }

    private struct PricingKey: Hashable {
        let provider: TokenMeterProvider
        let model: String?
    }

    private struct AttributionKey: Hashable {
        let provider: TokenMeterProvider
        let cwd: String
    }

    private struct Attribution {
        let agentID: AgentID?
        let ambiguous: Bool
    }
}
