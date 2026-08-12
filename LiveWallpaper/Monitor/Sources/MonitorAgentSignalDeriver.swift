import Foundation

/// Derives agent-session signals shared by the Claude and Codex session models.
enum MonitorAgentSignalDeriver {
    static let recentEventCap = 60
    static let recentToolCap = 8

    static let toolLoopRun = 8
    static let toolLoopWindow: TimeInterval = 10 * 60

    /// A running+alive session with no new event for longer than this is "stale".
    static let staleAfter: TimeInterval = 5 * 60

    static let toolNameMaxLength = 64

    private static let toolNameAllowed = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.:-"
    )

    /// Sanitize a raw tool name pulled verbatim from a transcript before it is ever stored or rendered as a "tool name" in the UI.
    static func sanitizedToolName(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= toolNameMaxLength else { return nil }
        guard trimmed.unicodeScalars.allSatisfy({ toolNameAllowed.contains($0) }) else { return nil }
        let name = trimmed.split(separator: ".").last.map(String.init) ?? trimmed
        return name.isEmpty ? nil : name
    }

    static func trimmedEventTimes(_ times: [Double], cap: Int = recentEventCap) -> [Double]? {
        guard !times.isEmpty else { return nil }
        let sorted = times.sorted()
        let capped = sorted.count > cap ? Array(sorted.suffix(cap)) : sorted
        return capped
    }

    static func trimmedTools(_ tools: [MonitorAgentToolEvent], cap: Int = recentToolCap) -> [MonitorAgentToolEvent]? {
        guard !tools.isEmpty else { return nil }
        let sorted = tools.sorted { $0.at < $1.at }
        let capped = sorted.count > cap ? Array(sorted.suffix(cap)) : sorted
        return capped
    }

    static func warning(
        recentTools: [MonitorAgentToolEvent],
        status: MonitorAgentStatus,
        processAlive: Bool,
        lastEventAt: Double?,
        now: Double
    ) -> String? {
        if isToolLoop(recentTools) { return "toolLoop" }
        if status == .running, processAlive, let last = lastEventAt, now - last > staleAfter {
            return "stale"
        }
        return nil
    }

    static func isToolLoop(_ tools: [MonitorAgentToolEvent]) -> Bool {
        guard tools.count >= toolLoopRun else { return false }
        let tail = Array(tools.sorted { $0.at < $1.at }.suffix(toolLoopRun))
        guard let first = tail.first, let last = tail.last else { return false }
        guard last.at - first.at <= toolLoopWindow else { return false }
        return tail.allSatisfy { $0.name == first.name }
    }
}

/// Worktree name extraction from a session cwd.
enum MonitorWorktree {
    static func name(fromCwd cwd: String?) -> String? {
        guard let cwd, !cwd.isEmpty else { return nil }
        let components = (cwd as NSString).pathComponents
        // Find the ".../.claude/worktrees/<name>/..." segment and take the segment immediately after "worktrees".
        guard let worktreesIndex = components.firstIndex(where: { $0 == "worktrees" }),
              worktreesIndex >= 1, components[worktreesIndex - 1] == ".claude",
              worktreesIndex + 1 < components.count else {
            return nil
        }
        let name = components[worktreesIndex + 1]
        return name.isEmpty || name == "/" ? nil : name
    }
}

/// In-memory tracker of when each session's status last flipped INTO `needsInput`, keyed by session id.
struct MonitorAgentWaitTracker {
    private var waitSince: [String: Double] = [:]

    /// Update the tracked flip time for `sessionId` given its current status and the event time to stamp a fresh transition with.
    mutating func waitSince(
        sessionID: String,
        status: MonitorAgentStatus,
        eventTime: Double
    ) -> Double? {
        if status == .needsInput {
            if let existing = waitSince[sessionID] { return existing }
            waitSince[sessionID] = eventTime
            return eventTime
        } else {
            waitSince[sessionID] = nil
            return nil
        }
    }

    mutating func retainOnly(_ liveIDs: Set<String>) {
        waitSince = waitSince.filter { liveIDs.contains($0.key) }
    }
}
