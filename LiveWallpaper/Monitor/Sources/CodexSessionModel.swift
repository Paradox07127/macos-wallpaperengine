import Foundation

struct CodexSessionModel: Sendable {
    var activity = AgentActivityState()
    private(set) var parentSessionID: String?
    private var lastUsageRecordAt: Date?
    private(set) var sessionId: String?
    private(set) var projectName: String?
    private(set) var gitBranch: String?
    private(set) var model: String?
    private(set) var turnCount = 0
    private(set) var tokens: MonitorTokenTotals = .zero
    private(set) var lastEventAt: Date?
    private(set) var lastToolName: String?
    private(set) var startedAt: Date?
    private(set) var lastTerminalEventIsTaskComplete = false
    private(set) var cwd: String?

    private(set) var lastUsageInput: Int?
    private(set) var lastUsageCacheRead: Int?
    private(set) var recentEventTimes: [Double] = []
    private(set) var recentTools: [MonitorAgentToolEvent] = []

    private var pendingApprovalAt: Date?
    private var lastApprovalClearAt: Date?
    private var lastStatusEventAt: Date?

    /// Explicit because the synthesized memberwise initializer isn't portable: Swift 6.4 gives
    /// optional/defaulted members implicit defaults so `CodexSessionModel(sessionId:)` resolves, while 6.3.3
    /// (the pinned shipping toolchain) synthesizes only `init()` — relying on the synthesized form builds under
    /// the beta and fails the release build.
    init(sessionId: String? = nil) {
        self.sessionId = sessionId
    }

    var pendingApproval: Bool {
        pendingApprovalAt != nil
    }

    mutating func ingest(_ lineData: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: lineData),
              let line = object as? [String: Any] else {
            return
        }
        ingest(decodedLine: line)
    }

    mutating func ingest(decodedLine line: [String: Any]) {
        let payload = line["payload"] as? [String: Any] ?? [:]
        let timestamp = Self.timestamp(from: line, payload: payload)
        guard let lineType = Self.stringValue(line["type"]) else { return }
        let payloadType = payload["type"] as? String ?? ""
        let eventTypes: Set = ["task_started", "task_complete", "task_aborted", "turn_aborted",
                               "agent_message", "user_message", "item_completed", "token_count", "exec_approval_request",
                               "apply_patch_approval_request", "exec_approval_response", "apply_patch_approval_response"]
        let responseTypes: Set = ["function_call", "custom_tool_call", "local_shell_call", "web_search_call",
                                  "function_call_output", "custom_tool_call_output", "message"]
        guard ["session_meta", "turn_context", "token_usage_record", "compacted"].contains(lineType)
            || (lineType == "event_msg" && eventTypes.contains(payloadType))
            || (lineType == "response_item" && responseTypes.contains(payloadType)) else { return }
        if lineType == "response_item", payloadType == "message",
           !["user", "assistant"].contains(payload["role"] as? String ?? "") {
            return
        }
        if payloadType == "item_completed" {
            let item = payload["item"] as? [String: Any] ?? [:]
            let type = (item["type"] as? String ?? "").lowercased()
            // Reasoning summaries and duplicate message completions add no
            // actionable tool activity; context compaction only resets usage.
            if type == "contextcompaction" {
                activity.contextTokens = nil
                return
            }
            guard ["commandexecution", "filechange", "websearch", "mcptoolcall"].contains(type) else { return }
        }
        let bookkeeping = lineType == "token_usage_record" || lineType == "turn_context" || payloadType == "token_count"
        if !bookkeeping, let timestamp {
            markFresh(at: timestamp)
            if lineType != "session_meta" {
                AgentSignalDeriver.appendRecentEventTime(&recentEventTimes, timestamp.timeIntervalSince1970)
            }
        }
        if let discoveredModel = Self.discoveredModel(in: payload) {
            model = discoveredModel
        }
        switch lineType {
        case "session_meta":
            ingestSessionMeta(payload)
        case "token_usage_record":
            if let usage = payload["thread_token_usage"] as? [String: Any] {
                tokens = Self.tokenTotals(from: usage)
                lastUsageRecordAt = timestamp
            }
        case "compacted":
            activity.contextTokens = nil
        case "turn_context":
            // Repeated every turn, unlike session_meta which appears once at line 1.
            // A >20 MiB rollout starts mid-file and never sees that first line, so
            // without this the project name degrades to the literal "Codex".
            ingestLocationMetadata(payload)
        case "event_msg":
            ingestEvent(payload, timestamp: timestamp)
        case "response_item":
            ingestResponseItem(payload, timestamp: timestamp)
        default:
            break
        }
    }

    func status(
        now: Date,
        processAlive: Bool,
        freshnessTimeout: TimeInterval = 180
    ) -> MonitorAgentStatus {
        guard let lastEventAt else { return .unknown }
        guard activity.turnStartedAt != nil || !activity.tools.isEmpty
            || lastTerminalEventIsTaskComplete || pendingApproval else { return .unknown }
        let age = max(0, now.timeIntervalSince(lastEventAt))

        if pendingApproval || activity.phase == .waitingForInput, processAlive {
            return .needsInput
        }
        // A completed turn settles the session even if the file is still warm.
        if lastTerminalEventIsTaskComplete, processAlive {
            return .idle
        }
        // An unfinished task while the process is alive stays running regardless
        // of how quiet the transcript has gone — a long tool writes nothing. The
        // 5-minute `stale` warning is what surfaces a suspicious one.
        if !lastTerminalEventIsTaskComplete, processAlive {
            return .running
        }
        if age < 15, !lastTerminalEventIsTaskComplete {
            return .running
        }
        if age >= freshnessTimeout {
            return processAlive ? .idle : .ended
        }
        return .unknown
    }

    var worktreeName: String? {
        MonitorWorktree.name(fromCwd: cwd)
    }

    func sessionState(
        now: Date,
        processAlive: Bool,
        fallbackSessionId: String,
        fallbackProjectName: String
    ) -> MonitorAgentSessionState? {
        guard let lastEventAt else { return nil }
        let resolvedSessionId = sessionId ?? fallbackSessionId
        let currentStatus = status(now: now, processAlive: processAlive)
        var state = MonitorAgentSessionState(
            id: "codex:\(resolvedSessionId)",
            provider: .codex,
            projectName: projectName ?? fallbackProjectName,
            status: currentStatus,
            statusDetail: currentStatus == .running ? lastToolName : nil,
            model: model,
            gitBranch: gitBranch,
            startedAt: startedAt?.timeIntervalSince1970,
            lastEventAt: lastEventAt.timeIntervalSince1970,
            processAlive: processAlive,
            turnCount: turnCount,
            tokens: tokens
        )
        state.recentEventTimes = AgentSignalDeriver.trimmedEventTimes(recentEventTimes)
        state.recentTools = AgentSignalDeriver.trimmedTools(recentTools)
        state.warning = AgentSignalDeriver.warning(
            recentTools: recentTools,
            status: currentStatus,
            processAlive: processAlive,
            lastEventAt: lastEventAt.timeIntervalSince1970,
            now: now.timeIntervalSince1970
        )
        state.worktreeName = worktreeName
        state.parentSessionID = parentSessionID
        activity.apply(to: &state)
        return state
    }

    func snapshotState() -> SessionAggregateState {
        var state = SessionAggregateState(
            provider: .codex,
            sessionId: sessionId,
            projectName: projectName,
            gitBranch: gitBranch,
            model: model,
            turnCount: turnCount,
            tokens: tokens,
            startedAt: startedAt?.timeIntervalSince1970,
            lastEventAt: lastEventAt?.timeIntervalSince1970,
            lastToolName: lastToolName,
            pendingApprovalAt: pendingApprovalAt?.timeIntervalSince1970,
            lastApprovalClearAt: lastApprovalClearAt?.timeIntervalSince1970,
            lastStatusEventAt: lastStatusEventAt?.timeIntervalSince1970,
            lastTerminalEventIsTaskComplete: lastTerminalEventIsTaskComplete
        )
        state.activity = activity.checkpoint()
        return state
    }

    static func restore(from state: SessionAggregateState) -> CodexSessionModel? {
        guard state.provider == .codex else { return nil }
        var model = CodexSessionModel()
        model.activity = state.activity ?? AgentActivityState()
        model.sessionId = state.sessionId
        model.projectName = state.projectName
        model.gitBranch = state.gitBranch
        model.model = state.model
        model.turnCount = state.turnCount
        model.tokens = state.tokens
        model.startedAt = state.startedAt.map { Date(timeIntervalSince1970: $0) }
        model.lastEventAt = state.lastEventAt.map { Date(timeIntervalSince1970: $0) }
        model.lastToolName = state.lastToolName
        model.pendingApprovalAt = state.pendingApprovalAt.map { Date(timeIntervalSince1970: $0) }
        model.lastApprovalClearAt = state.lastApprovalClearAt.map { Date(timeIntervalSince1970: $0) }
        model.lastStatusEventAt = state.lastStatusEventAt.map { Date(timeIntervalSince1970: $0) }
        model.lastTerminalEventIsTaskComplete = state.lastTerminalEventIsTaskComplete ?? false
        return model
    }

    // MARK: - Ingestion

    private mutating func ingestSessionMeta(_ payload: [String: Any]) {
        sessionId = Self.stringValue(payload["id"]) ?? Self.stringValue(payload["session_id"]) ?? sessionId
        parentSessionID = Self.stringValue(payload["parent_thread_id"]).map { "codex:" + $0 }
        ingestLocationMetadata(payload)
        activity.contextWindow = Self.intValue(payload["context_window"])
    }

    /// cwd + branch, from either `session_meta` (once, at line 1) or `turn_context`
    /// (every turn). Shared so a cold start that misses line 1 still resolves them.
    private mutating func ingestLocationMetadata(_ payload: [String: Any]) {
        if let cwd = Self.stringValue(payload["cwd"]), !cwd.isEmpty {
            self.cwd = cwd
            let name = URL(fileURLWithPath: cwd).lastPathComponent
            if !name.isEmpty {
                projectName = name
            }
        }

        if let git = payload["git"] as? [String: Any] {
            gitBranch = Self.stringValue(git["branch"]) ?? gitBranch
        }
    }

    private mutating func ingestEvent(_ payload: [String: Any], timestamp: Date?) {
        guard let payloadType = Self.stringValue(payload["type"]) else { return }

        switch payloadType {
        case "task_started":
            if activity.beginTurn(id: Self.stringValue(payload["turn_id"]), at: timestamp?.timeIntervalSince1970 ?? 0) {
                turnCount += 1
            }
            activity.contextWindow = Self.intValue(payload["model_context_window"]) ?? activity.contextWindow
            if let timestamp {
                clearPendingApproval(at: timestamp)
                markTerminal(false, at: timestamp)
            }
        case "item_completed":
            ingestCompletedItem(payload, timestamp: timestamp)
        case "task_aborted", "turn_aborted":
            activity.finish(.interrupted, at: timestamp?.timeIntervalSince1970 ?? 0)
            lastToolName = nil
            if let timestamp {
                markTerminal(true, at: timestamp)
                clearPendingApproval(at: timestamp)
            }
        case "task_complete":
            activity.finish(.completed, at: timestamp?.timeIntervalSince1970 ?? 0)
            if let timestamp {
                clearPendingApproval(at: timestamp)
                markTerminal(true, at: timestamp)
            }
            // The turn is over; the last tool is history, not current activity.
            lastToolName = nil
        case "agent_message", "user_message":
            if let timestamp {
                clearPendingApproval(at: timestamp)
                if payloadType == "user_message" {
                    if lastTerminalEventIsTaskComplete {
                        activity.beginTurn(id: nil, at: timestamp.timeIntervalSince1970)
                    }
                    markTerminal(false, at: timestamp)
                }
                if activity.pendingCount == 0 {
                    activity.transition(.responding, at: timestamp.timeIntervalSince1970)
                }
            }
        case "token_count":
            if lastUsageRecordAt == nil || timestamp.map({ $0 > lastUsageRecordAt! }) == true {
                ingestTokenCount(payload)
            }
        default:
            if Self.isApprovalRequest(payloadType) {
                if let timestamp {
                    markPendingApproval(at: timestamp)
                    activity.transition(.waitingForApproval, at: timestamp.timeIntervalSince1970)
                    markTerminal(false, at: timestamp)
                }
            } else if Self.isApprovalResolution(payloadType), let timestamp {
                clearPendingApproval(at: timestamp)
                activity.transition(.responding, at: timestamp.timeIntervalSince1970)
            }
        }
    }

    private mutating func ingestResponseItem(_ payload: [String: Any], timestamp: Date?) {
        let at = timestamp?.timeIntervalSince1970 ?? lastEventAt?.timeIntervalSince1970 ?? 0
        let type = payload["type"] as? String ?? ""
        let id = Self.stringValue(payload["call_id"]) ?? Self.stringValue(payload["id"]) ?? "anonymous:\(at)"
        if type.hasSuffix("_output") {
            // A result's text is not a success protocol; only structured results can supply ok.
            activity.endTool(id: id, at: at, ok: nil)
            lastToolName = activity.currentTool
        } else if let toolName = Self.toolName(from: payload) {
            activity.beginTool(id: id, name: toolName, at: at)
            lastToolName = activity.currentTool
            if let timestamp {
                markTerminal(false, at: timestamp)
            }
        }
        recentTools = activity.tools
    }

    private mutating func ingestCompletedItem(_ payload: [String: Any], timestamp: Date?) {
        guard let item = payload["item"] as? [String: Any], let id = Self.stringValue(item["id"]) else { return }
        let type = (item["type"] as? String ?? "").lowercased()
        let names = ["commandexecution": "shell", "filechange": "file_change", "websearch": "web_search", "mcptoolcall": "mcp"]
        let at = ((payload["completed_at_ms"] as? NSNumber)?.doubleValue).map { $0 / 1000 } ?? timestamp?.timeIntervalSince1970 ?? 0
        if type == "contextcompaction" {
            activity.contextTokens = nil; return
        }
        guard let name = names[type] else { return }
        let start = ((payload["started_at_ms"] as? NSNumber)?.doubleValue).map { $0 / 1000 } ?? at
        let status = (item["status"] as? String ?? "").lowercased()
        let code = Self.intValue(item["exit_code"])
        let ok: Bool? = code.map { $0 == 0 } ?? (["completed", "success"].contains(status) ? true : (["failed", "declined"].contains(status) ? false : nil))
        activity.beginTool(id: id, name: name, at: start)
        activity.endTool(id: id, at: at, ok: ok, duration: max(0, at - start))
        recentTools = activity.tools
        lastToolName = activity.currentTool
    }

    private mutating func ingestTokenCount(_ payload: [String: Any]) {
        if let info = payload["info"] as? [String: Any] {
            activity.contextWindow = Self.intValue(info["model_context_window"]) ?? activity.contextWindow
            if let usage = info["last_token_usage"] as? [String: Any] {
                activity.contextTokens = Self.intValue(usage["input_tokens"])
            }
            if let total = info["total_token_usage"] as? [String: Any] {
                tokens = Self.tokenTotals(from: total)
                recordLastUsage(from: (info["last_token_usage"] as? [String: Any]) ?? total)
                return
            }
            if let last = info["last_token_usage"] as? [String: Any] {
                tokens = tokens + Self.tokenTotals(from: last)
                recordLastUsage(from: last)
                return
            }
        }

        if let total = payload["total_token_usage"] as? [String: Any] {
            tokens = Self.tokenTotals(from: total)
            recordLastUsage(from: total)
        } else if let last = payload["last_token_usage"] as? [String: Any] {
            tokens = tokens + Self.tokenTotals(from: last)
            recordLastUsage(from: last)
        }
    }

    private mutating func recordLastUsage(from usage: [String: Any]) {
        let totals = Self.tokenTotals(from: usage)
        lastUsageInput = totals.input
        lastUsageCacheRead = totals.cacheRead
    }

    // MARK: - State helpers

    private mutating func markFresh(at date: Date) {
        if startedAt == nil {
            startedAt = date
        }
        if lastEventAt == nil || date >= (lastEventAt ?? date) {
            lastEventAt = date
        }
    }

    private mutating func markTerminal(_ isTaskComplete: Bool, at date: Date) {
        guard lastStatusEventAt == nil || date >= (lastStatusEventAt ?? date) else { return }
        lastStatusEventAt = date
        lastTerminalEventIsTaskComplete = isTaskComplete
    }

    private mutating func markPendingApproval(at date: Date) {
        if let lastApprovalClearAt, date <= lastApprovalClearAt {
            return
        }
        pendingApprovalAt = date
    }

    private mutating func clearPendingApproval(at date: Date) {
        if lastApprovalClearAt == nil || date >= (lastApprovalClearAt ?? date) {
            lastApprovalClearAt = date
        }
        if let pendingApprovalAt, date >= pendingApprovalAt {
            self.pendingApprovalAt = nil
        }
    }

    // MARK: - Parsing helpers

    private static func timestamp(from line: [String: Any], payload: [String: Any]) -> Date? {
        let value = stringValue(line["timestamp"]) ?? stringValue(payload["timestamp"])
        guard let value else { return nil }
        return parseTimestamp(value)
    }

    private static func parseTimestamp(_ value: String) -> Date? {
        (try? Date(value, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
            ?? (try? Date(value, strategy: .iso8601))
    }

    private static func discoveredModel(in payload: [String: Any]) -> String? {
        if let model = stringValue(payload["model"]) {
            return model
        }
        if let collaboration = payload["collaboration_mode"] as? [String: Any],
           let settings = collaboration["settings"] as? [String: Any],
           let model = stringValue(settings["model"]) {
            return model
        }
        if let info = payload["info"] as? [String: Any],
           let model = stringValue(info["model"]) {
            return model
        }
        return nil
    }

    private static func toolName(from payload: [String: Any]) -> String? {
        guard let payloadType = stringValue(payload["type"]) else { return nil }
        if payloadType == "local_shell_call" {
            return "shell"
        }
        if payloadType == "web_search_call" {
            return "web_search"
        }
        if let name = stringValue(payload["name"]) {
            return sanitizedToolName(name)
        }
        if payloadType.hasSuffix("_call") {
            return sanitizedToolName(String(payloadType.dropLast(5)))
        }
        return nil
    }

    private static func sanitizedToolName(_ value: String) -> String? {
        guard let name = AgentSignalDeriver.sanitizedToolName(value) else { return nil }
        if name == "exec_command" {
            return "shell"
        }
        return name
    }

    private static func isApprovalRequest(_ value: String) -> Bool {
        let lowercased = value.lowercased()
        guard lowercased.contains("approval") else { return false }
        return lowercased.contains("request") || !isApprovalResolution(value)
    }

    private static func isApprovalResolution(_ value: String) -> Bool {
        let lowercased = value.lowercased()
        return lowercased.contains("response")
            || lowercased.contains("approved")
            || lowercased.contains("denied")
            || lowercased.contains("rejected")
            || lowercased.contains("resolved")
    }

    private static func tokenTotals(from usage: [String: Any]) -> MonitorTokenTotals {
        MonitorTokenTotals(
            input: intValue(usage["input_tokens"]) ?? intValue(usage["input"]) ?? 0,
            output: intValue(usage["output_tokens"]) ?? intValue(usage["output"]) ?? 0,
            cacheRead: intValue(usage["cached_input_tokens"])
                ?? intValue(usage["cache_read_tokens"])
                ?? intValue(usage["cacheRead"])
                ?? 0,
            cacheWrite: intValue(usage["cache_write_input_tokens"])
                ?? intValue(usage["cache_write_tokens"])
                ?? intValue(usage["cache_creation_input_tokens"])
                ?? intValue(usage["cacheWrite"])
                ?? 0
        )
    }

    private static func stringValue(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int {
            return int
        }
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            return number.intValue
        }
        if let string = stringValue(value) {
            return Int(string)
        }
        return nil
    }
}
