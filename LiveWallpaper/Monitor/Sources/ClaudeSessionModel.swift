import Foundation

struct ClaudeTranscriptLine {
    enum Role: Equatable {
        case user
        case assistant
        case system
        case other(String)
    }

    var type: Role
    var timestamp: Date?
    var isSidechain: Bool
    var cwd: String?
    var gitBranch: String?
    var sessionId: String?

    var model: String?
    var stopReason: String?
    var toolNames: [String]          // names of tool_use content blocks, in order
    var toolUses: [ToolUse]          // tool_use blocks with their ids, in order
    var toolResults: [ToolResult]    // tool_result blocks (paired back by tool_use_id)
    var hasTextOutput: Bool          // assistant emitted a text/thinking block
    var usage: Usage?                // flattened assistant token usage, if present

    /// One tool_use content block, name + optional id (name only — never args).
    struct ToolUse: Equatable { var name: String; var id: String? }
    struct ToolResult: Equatable { var toolUseID: String?; var isError: Bool }

    /// Flattened assistant token usage. Reads only the four canonical top-level
    /// fields; nested `iterations`/`cache_creation` detail is ignored.
    struct Usage: Equatable {
        var input: Int
        var output: Int
        var cacheRead: Int
        var cacheWrite: Int
    }

    var isToolResult: Bool           // content is a tool_result array (not a real prompt)
    var isRealUserPrompt: Bool       // content is a plain string or text block(s)

    /// Parse a single JSONL line. Returns nil only when the bytes are not an
    /// object at all; unknown *types* still decode successfully.
    init?(data: Data) {
        guard
            let object = try? JSONSerialization.jsonObject(with: data),
            let dict = object as? [String: Any]
        else { return nil }
        self.init(dict: dict)
    }

    init(dict: [String: Any]) {
        let typeString = dict["type"] as? String ?? "other"
        switch typeString {
        case "user": self.type = .user
        case "assistant": self.type = .assistant
        case "system": self.type = .system
        default: self.type = .other(typeString)
        }

        self.timestamp = (dict["timestamp"] as? String).flatMap(Self.parseTimestamp)
        self.isSidechain = dict["isSidechain"] as? Bool ?? false
        self.cwd = dict["cwd"] as? String
        self.gitBranch = dict["gitBranch"] as? String
        self.sessionId = dict["sessionId"] as? String

        let message = dict["message"] as? [String: Any]
        self.model = message?["model"] as? String
        self.stopReason = message?["stop_reason"] as? String

        var tools: [String] = []
        var toolUses: [ToolUse] = []
        var toolResults: [ToolResult] = []
        var sawText = false
        var sawToolResult = false
        var sawTextContentBlock = false

        if let content = message?["content"] as? [[String: Any]] {
            for block in content {
                switch block["type"] as? String {
                case "tool_use":
                    if let name = block["name"] as? String {
                        tools.append(name)
                        toolUses.append(ToolUse(name: name, id: block["id"] as? String))
                    }
                case "text", "thinking":
                    sawText = true
                    sawTextContentBlock = true
                case "tool_result":
                    sawToolResult = true
                    let isError = (block["is_error"] as? Bool) ?? false
                    toolResults.append(ToolResult(toolUseID: block["tool_use_id"] as? String, isError: isError))
                default:
                    break
                }
            }
        }
        self.toolNames = tools
        self.toolUses = toolUses
        self.toolResults = toolResults
        self.hasTextOutput = sawText

        if self.type == .assistant, let usageDict = message?["usage"] as? [String: Any] {
            self.usage = Usage(
                input: (usageDict["input_tokens"] as? Int) ?? 0,
                output: (usageDict["output_tokens"] as? Int) ?? 0,
                cacheRead: (usageDict["cache_read_input_tokens"] as? Int) ?? 0,
                cacheWrite: (usageDict["cache_creation_input_tokens"] as? Int) ?? 0
            )
        } else {
            self.usage = nil
        }

        let contentIsString = message?["content"] is String
        self.isToolResult = (self.type == .user) && sawToolResult && !contentIsString
        self.isRealUserPrompt = (self.type == .user) && (contentIsString || (sawTextContentBlock && !sawToolResult))
    }

    static func parseTimestamp(_ string: String) -> Date? {
        try? Date(string, strategy: .iso8601)
    }
}

/// Pure, I/O-free accumulator + classifier for one Claude Code session.
struct ClaudeSessionModel {
    private(set) var sessionId: String
    private(set) var projectName: String?
    private(set) var gitBranch: String?
    private(set) var model: String?

    private(set) var turnCount: Int = 0
    private(set) var tokens: MonitorTokenTotals = .zero
    private(set) var lastEventAt: Date?
    private(set) var startedAt: Date?
    private(set) var lastToolName: String?
    private(set) var cwd: String?

    /// tool_use ids the assistant issued that have no matching tool_result yet,
    /// in issue order. A bool cannot represent parallel calls, and the transcript
    /// routinely has several in flight at once.
    private(set) var outstandingToolIDs: [String] = []
    /// Subset of the above whose tool is `AskUserQuestion` — the session is
    /// blocked on a human, not on a tool.
    private(set) var outstandingAskIDs: Set<String> = []
    /// Parallel to `recentTools`, trimmed in lockstep, so a result can be matched
    /// back to the exact call. Kept out of `MonitorAgentToolEvent` because that
    /// type is the wire contract pushed to the renderer.
    private var recentToolIDs: [String] = []
    private var anonymousToolCounter: UInt64 = 0
    private(set) var lastAssistantStopReason: String?

    var pendingToolUse: Bool { !outstandingToolIDs.isEmpty }
    /// The one tool whose outstanding call means "a human must answer".
    static let askUserToolName = "AskUserQuestion"

    private static func synthesizedToolID(_ n: UInt64) -> String { "anon:\(n)" }

    /// A call whose result never arrives (killed CLI, crashed subprocess) would
    /// otherwise sit in `outstandingToolIDs` forever — and it is persisted.
    /// Far above any real parallel fan-out.
    static let outstandingToolCap = 64

    private(set) var lastUsageInput: Int?
    private(set) var lastUsageCacheRead: Int?
    private(set) var recentEventTimes: [Double] = []
    private(set) var recentTools: [MonitorAgentToolEvent] = []

    private(set) var lastInboundAwaitsModel: Bool = false

    init(sessionId: String) {
        self.sessionId = sessionId
    }

    mutating func ingest(_ line: ClaudeTranscriptLine) {
        if let ts = line.timestamp {
            if lastEventAt == nil || ts > lastEventAt! { lastEventAt = ts }
            if startedAt == nil || ts < startedAt! { startedAt = ts }
        }
        if sessionId.isEmpty, let sid = line.sessionId { sessionId = sid }
        if let cwd = line.cwd, !cwd.isEmpty {
            projectName = (cwd as NSString).lastPathComponent
            self.cwd = cwd
        }
        if let branch = line.gitBranch, !branch.isEmpty { gitBranch = branch }

        if let ts = line.timestamp?.timeIntervalSince1970 {
            MonitorAgentSignalDeriver.appendRecentEventTime(&recentEventTimes, ts)
        }

        guard !line.isSidechain else { return }

        switch line.type {
        case .assistant:
            if let model = line.model { self.model = model }
            accumulateTokens(from: line)
            recordLastUsage(from: line)
            recordToolUses(from: line)
            if let stop = line.stopReason { lastAssistantStopReason = stop }
            if let tool = line.toolNames.last {
                lastToolName = MonitorAgentSignalDeriver.sanitizedToolName(tool)
            }
            // The assistant just spoke, so nothing is awaiting the model.
            lastInboundAwaitsModel = false

        case .user:
            if line.isToolResult {
                applyToolResults(from: line)
                lastInboundAwaitsModel = true
            } else if line.isRealUserPrompt {
                turnCount += 1
                // A fresh human turn supersedes anything still outstanding.
                outstandingToolIDs.removeAll()
                outstandingAskIDs.removeAll()
                lastInboundAwaitsModel = true
            }

        case .system:
            break

        case .other:
            break
        }
    }

    private mutating func accumulateTokens(from line: ClaudeTranscriptLine) {
        guard let usage = line.usage else { return }
        tokens.input += usage.input
        tokens.output += usage.output
        tokens.cacheRead += usage.cacheRead
        tokens.cacheWrite += usage.cacheWrite
    }

    private mutating func recordLastUsage(from line: ClaudeTranscriptLine) {
        guard let usage = line.usage else { return }
        lastUsageInput = usage.input
        lastUsageCacheRead = usage.cacheRead
    }

    private mutating func recordToolUses(from line: ClaudeTranscriptLine) {
        let at = line.timestamp?.timeIntervalSince1970 ?? lastEventAt?.timeIntervalSince1970 ?? 0
        for use in line.toolUses {
            // A tool_use without an id still occupies the model; synthesize one so
            // it is tracked like any other and an id-less result can retire it.
            let id = use.id ?? Self.synthesizedToolID(anonymousToolCounter)
            if use.id == nil { anonymousToolCounter &+= 1 }
            // Outstanding-ness is about the call happening, not about whether its
            // name is safe to render: a tool we refuse to name is still running.
            outstandingToolIDs.append(id)
            if use.name == Self.askUserToolName { outstandingAskIDs.insert(id) }
            if outstandingToolIDs.count > Self.outstandingToolCap {
                let dropped = outstandingToolIDs.removeFirst()
                outstandingAskIDs.remove(dropped)
            }
            guard let name = MonitorAgentSignalDeriver.sanitizedToolName(use.name) else { continue }
            recentTools.append(MonitorAgentToolEvent(name: name, at: at, ok: nil))
            recentToolIDs.append(id)
        }
        let cap = MonitorAgentSignalDeriver.recentToolCap * 3
        if recentTools.count > cap {
            recentTools = Array(recentTools.suffix(cap))
            recentToolIDs = Array(recentToolIDs.suffix(cap))
        }
    }

    /// Results arrive out of order when the assistant issues parallel calls, so
    /// match on `tool_use_id`. Only a result that carries no id falls back to
    /// "oldest unresolved", and that fallback must not retire a different call's
    /// outstanding state.
    private mutating func applyToolResults(from line: ClaudeTranscriptLine) {
        for result in line.toolResults {
            if let id = result.toolUseID {
                if let index = recentToolIDs.firstIndex(of: id), recentTools.indices.contains(index) {
                    recentTools[index].ok = !result.isError
                }
                outstandingToolIDs.removeAll { $0 == id }
                outstandingAskIDs.remove(id)
            } else {
                // No id to match on. Retire the oldest outstanding call — that is
                // the authoritative list, and it survives a cursor restore where
                // the rendered-event arrays start empty. Marking the oldest
                // unresolved rendered event is best-effort and independent: a call
                // whose name failed sanitization has no rendered event at all.
                if let index = recentTools.firstIndex(where: { $0.ok == nil }) {
                    recentTools[index].ok = !result.isError
                }
                if !outstandingToolIDs.isEmpty {
                    let id = outstandingToolIDs.removeFirst()
                    outstandingAskIDs.remove(id)
                }
            }
        }
    }

    // MARK: - Classification

    func status(now: Date, processAlive: Bool, freshnessTimeout: TimeInterval = 180) -> MonitorAgentStatus {
        let age = lastEventAt.map { now.timeIntervalSince($0) } ?? .greatestFiniteMagnitude
        let isFresh = age < 15
        let isVeryStale = age >= freshnessTimeout

        // Blocked on a human: an AskUserQuestion call the user has not answered.
        //    This is the transcript's own signal; the old probe searched system
        //    lines for "permission"/"approval" and matched nothing in practice.
        if !outstandingAskIDs.isEmpty && processAlive {
            return .needsInput
        }
        // Actively working. An outstanding tool call outranks freshness while
        //    the process is alive: a build or a test run can go minutes without
        //    writing a transcript event, and calling that "idle" was wrong. The
        //    `stale` warning (5 min silent) is what flags a suspicious one.
        if pendingToolUse && processAlive {
            return .running
        }
        if isFresh && (pendingToolUse || lastInboundAwaitsModel) {
            return .running
        }
        if lastAssistantStopReason == "end_turn" && processAlive {
            return .idle
        }
        // No activity for a long while: idle if alive, otherwise ended.
        if isVeryStale {
            return processAlive ? .idle : .ended
        }
        if !processAlive {
            return .ended
        }
        // Fresh but ambiguous ⇒ running; otherwise unknown.
        return isFresh ? .running : .unknown
    }

    /// Short, privacy-safe detail string. Only ever a tool name — never any
    /// prompt or output text (hard privacy invariant).
    func statusDetail(now: Date, processAlive: Bool, freshnessTimeout: TimeInterval = 180) -> String? {
        guard status(now: now, processAlive: processAlive, freshnessTimeout: freshnessTimeout) == .running else { return nil }
        return pendingToolUse ? lastToolName : nil
    }

    var worktreeName: String? { MonitorWorktree.name(fromCwd: cwd) }

    func snapshot(now: Date, processAlive: Bool, freshnessTimeout: TimeInterval = 180) -> MonitorAgentSessionState {
        let currentStatus = status(now: now, processAlive: processAlive, freshnessTimeout: freshnessTimeout)
        let tools = MonitorAgentSignalDeriver.trimmedTools(recentTools)
        let warning = MonitorAgentSignalDeriver.warning(
            recentTools: recentTools,
            status: currentStatus,
            processAlive: processAlive,
            lastEventAt: lastEventAt?.timeIntervalSince1970,
            now: now.timeIntervalSince1970
        )
        var state = MonitorAgentSessionState(
            id: "claude:\(sessionId)",
            provider: .claude,
            projectName: projectName ?? sessionId,
            status: currentStatus,
            statusDetail: statusDetail(now: now, processAlive: processAlive, freshnessTimeout: freshnessTimeout),
            model: model,
            gitBranch: gitBranch,
            startedAt: startedAt?.timeIntervalSince1970,
            lastEventAt: (lastEventAt ?? .distantPast).timeIntervalSince1970,
            processAlive: processAlive,
            turnCount: turnCount,
            tokens: tokens
        )
        state.recentEventTimes = MonitorAgentSignalDeriver.trimmedEventTimes(recentEventTimes)
        state.recentTools = tools
        state.warning = warning
        state.worktreeName = worktreeName
        return state
    }

    func snapshotState() -> SessionAggregateState {
        SessionAggregateState(
            provider: .claude,
            sessionId: sessionId,
            projectName: projectName,
            gitBranch: gitBranch,
            model: model,
            turnCount: turnCount,
            tokens: tokens,
            startedAt: startedAt?.timeIntervalSince1970,
            lastEventAt: lastEventAt?.timeIntervalSince1970,
            lastToolName: lastToolName,
            pendingToolUse: pendingToolUse,
            lastAssistantStopReason: lastAssistantStopReason,
            outstandingToolIDs: outstandingToolIDs.isEmpty ? nil : outstandingToolIDs,
            outstandingAskIDs: outstandingAskIDs.isEmpty ? nil : Array(outstandingAskIDs),
            lastInboundAwaitsModel: lastInboundAwaitsModel
        )
    }

    static func restore(from state: SessionAggregateState, sessionId: String) -> ClaudeSessionModel? {
        guard state.provider == .claude else { return nil }
        var model = ClaudeSessionModel(sessionId: sessionId)
        model.projectName = state.projectName
        model.gitBranch = state.gitBranch
        model.model = state.model
        model.turnCount = state.turnCount
        model.tokens = state.tokens
        model.startedAt = state.startedAt.map { Date(timeIntervalSince1970: $0) }
        model.lastEventAt = state.lastEventAt.map { Date(timeIntervalSince1970: $0) }
        model.lastToolName = state.lastToolName
        model.lastAssistantStopReason = state.lastAssistantStopReason
        if let ids = state.outstandingToolIDs {
            model.outstandingToolIDs = ids
        } else if state.pendingToolUse == true {
            // Pre-2026-08-09 aggregate: it only knew "something was outstanding".
            model.outstandingToolIDs = [Self.synthesizedToolID(0)]
        }
        model.outstandingAskIDs = Set(state.outstandingAskIDs ?? [])
        model.lastInboundAwaitsModel = state.lastInboundAwaitsModel ?? false
        return model
    }
}
