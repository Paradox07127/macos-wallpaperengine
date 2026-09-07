import CryptoKit
import Foundation

enum MonitorAgentPhase: String, Codable, Sendable {
    case responding, executing, waitingForInput, waitingForApproval, waitingForAgents
    case completed, interrupted, failed, unknown
}

/// Only whitelisted metadata enters this reducer or its persisted checkpoint.
struct AgentActivityState: Codable, Sendable, Equatable {
    var phase: MonitorAgentPhase = .unknown
    var phaseStartedAt: Double?
    var turnStartedAt: Double?
    var completedAt: Double?
    var turnID: String?
    var partialHistory = false
    var contextTokens: Int?
    var contextWindow: Int?
    var tools: [MonitorAgentToolEvent] = []
    private var pending: [String: String] = [:]
    private var completedIDs: [String] = []
    private var usageReceipts: [String: MonitorTokenTotals] = [:]
    private var usageOrder: [String] = []

    var pendingCount: Int {
        pending.count
    }

    var currentTool: String? {
        tools.last(where: { $0.completedAt == nil })?.name
    }

    func checkpoint() -> Self {
        var copy = self
        copy.usageOrder = Array(usageOrder.suffix(64))
        copy.usageReceipts = usageReceipts.filter { copy.usageOrder.contains($0.key) }
        copy.tools = Array(tools.suffix(8))
        return copy
    }

    func apply(to state: inout MonitorAgentSessionState) {
        state.phase = phase
        state.phaseStartedAt = phaseStartedAt
        state.turnStartedAt = turnStartedAt
        state.completedAt = completedAt
        state.pendingToolCount = pendingCount
        state.partialHistory = partialHistory
        state.contextTokens = contextTokens
        state.contextWindow = contextWindow
        state.toolActivity = tools
        if !tools.isEmpty {
            state.recentTools = Array(tools.suffix(8))
        }
    }

    static func key(_ raw: String) -> String {
        SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    mutating func transition(_ next: MonitorAgentPhase, at time: Double) {
        guard time.isFinite, time >= (phaseStartedAt ?? -.greatestFiniteMagnitude) else { return }
        if phase != next {
            phaseStartedAt = time
        }
        phase = next
    }

    @discardableResult
    mutating func beginTurn(id: String?, at time: Double) -> Bool {
        let key = id.map(Self.key)
        guard key == nil || key != turnID else { return false }
        guard time >= (turnStartedAt ?? -.greatestFiniteMagnitude) else { return false }
        turnID = key
        turnStartedAt = time
        phaseStartedAt = time
        completedAt = nil
        closePendingTools(at: time)
        pending.removeAll()
        transition(.responding, at: time)
        return true
    }

    mutating func finish(_ outcome: MonitorAgentPhase, at time: Double) {
        guard time >= (turnStartedAt ?? -.greatestFiniteMagnitude) else { return }
        completedAt = time
        closePendingTools(at: time)
        pending.removeAll()
        transition(outcome, at: time)
    }

    mutating func beginTool(id: String, name: String, at time: Double) {
        guard time >= (turnStartedAt ?? -.greatestFiniteMagnitude) else { return }
        guard let name = AgentSignalDeriver.sanitizedToolName(name) else { return }
        let key = Self.key(id)
        guard pending[key] == nil, !completedIDs.contains(key) else { return }
        pending[key] = name
        tools.append(MonitorAgentToolEvent(name: name, at: time, ok: nil, id: key))
        if tools.count > 48 {
            tools.removeFirst(tools.count - 48)
        }
        if pending.count > 128 {
            pending = pending.filter { key, _ in tools.contains { $0.id == key } }
            partialHistory = true
        }
        let next: MonitorAgentPhase = switch name {
        case "AskUserQuestion", "request_user_input", "request_user_input_async": .waitingForInput
        case "wait_agent", "wait_threads": .waitingForAgents
        default: .executing
        }
        if phase != .waitingForInput, phase != .waitingForApproval {
            transition(next, at: time)
        }
    }

    mutating func endTool(id: String, at time: Double, ok: Bool?, duration: Double? = nil) {
        guard time >= (turnStartedAt ?? -.greatestFiniteMagnitude) else { return }
        let key = Self.key(id)
        pending[key] = nil
        if let index = tools.lastIndex(where: { $0.id == key }) {
            if tools[index].completedAt != nil, tools[index].ok != nil, ok == nil {
                return
            }
            tools[index].completedAt = time
            tools[index].ok = ok
            tools[index].durationSeconds = duration.map { max(0, $0) } ?? max(0, time - tools[index].at)
        }
        if !completedIDs.contains(key) {
            completedIDs.append(key)
        }
        if completedIDs.count > 256 {
            completedIDs.removeFirst(completedIDs.count - 256)
        }
        if completedAt == nil, phase != .waitingForApproval {
            let waiting = pending.values.contains { ["AskUserQuestion", "request_user_input", "request_user_input_async"].contains($0) }
            let waitingForAgents = pending.values.contains { ["wait_agent", "wait_threads"].contains($0) }
            transition(waiting ? .waitingForInput : (waitingForAgents ? .waitingForAgents : (pending.isEmpty ? .responding : .executing)), at: time)
        }
    }

    private mutating func closePendingTools(at time: Double) {
        for index in tools.indices where tools[index].completedAt == nil {
            tools[index].completedAt = time
            tools[index].interrupted = true
        }
    }

    /// Cumulative message usage can repeat across content blocks and increase later.
    /// Replace the receipt and apply its signed correction, also across cursor restores.
    mutating func account(_ usage: MonitorTokenTotals, id: String?, total: inout MonitorTokenTotals) {
        guard let id else {
            let previous = total
            total = previous + usage
            return
        }
        let key = Self.key(id)
        let old = usageReceipts[key] ?? .zero
        total = MonitorTokenTotals(
            input: max(0, total.input - old.input), output: max(0, total.output - old.output),
            cacheRead: max(0, total.cacheRead - old.cacheRead), cacheWrite: max(0, total.cacheWrite - old.cacheWrite)
        ) + usage
        if usageReceipts[key] == nil {
            usageOrder.append(key)
        }
        usageReceipts[key] = usage
        if usageOrder.count > 4096 {
            for key in usageOrder.prefix(1024) {
                usageReceipts[key] = nil
            }
            usageOrder.removeFirst(1024)
            partialHistory = true
        }
    }
}

extension MonitorAgentSessionState {
    var totalTokenCount: Int {
        provider == .claude ? (tokens + MonitorTokenTotals(input: tokens.cacheRead, output: tokens.cacheWrite)).total : tokens.total
    }

    var effectivePhase: MonitorAgentPhase {
        if status == .unknown {
            return .unknown
        }
        if status == .ended {
            if let phase, [.completed, .failed, .interrupted].contains(phase) {
                return phase
            }
            return .interrupted
        }
        return phase ?? (status == .needsInput ? .waitingForInput : .unknown)
    }
}
