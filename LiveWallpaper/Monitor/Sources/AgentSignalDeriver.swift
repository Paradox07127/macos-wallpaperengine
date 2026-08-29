import Foundation

/// Derives agent-session signals shared by the Claude and Codex session models.
enum AgentSignalDeriver {
    static let recentEventCap = 60
    static let recentToolCap = 8

    /// A run this long is a loop; anything shorter is an agent doing its job.
    ///
    /// This was 8, which flagged 23 of the 58 most recent local sessions —
    /// including ones whose entire "loop" was eight `Bash` calls in 61
    /// seconds. Only the tool *name* is compared (arguments are never stored,
    /// by the privacy invariant), so the run length is the only thing carrying
    /// the signal, and 8 sits below the 90th percentile of ordinary runs
    /// (measured over the same corpus: p50 = 1, p90 = 12, p99 = 48, max 295).
    /// 40 is just under that p99 and takes the corpus down to 2 sessions.
    static let toolLoopRun = 40
    /// Events kept per session for the detector — enough to see a whole run.
    /// Separate from `recentToolCap`, which is the display tail.
    static let toolLoopBuffer = 48
    static let toolLoopWindow: TimeInterval = 10 * 60

    /// A running+alive session with no new event for longer than this is "stale".
    ///
    /// Five minutes was shorter than the work: a full test run here is ~2 min,
    /// and a session that fans out to review subagents sits on one pending
    /// tool call for 5–9 minutes with nothing to write to the transcript. The
    /// chip fired on those every time, which is the same way `toolLoop` at 8
    /// stopped meaning anything.
    static let staleAfter: TimeInterval = 15 * 60

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

    /// Ingestion-time buffer growth guard: append, then only pay for a trim once
    /// the buffer reaches 2× the eventual display cap (`trimmedEventTimes` does
    /// the final sort+cap at snapshot time).
    static func appendRecentEventTime(_ times: inout [Double], _ time: Double) {
        times.append(time)
        if times.count > recentEventCap * 2 {
            times = Array(times.suffix(recentEventCap))
        }
    }

    static func trimmedEventTimes(_ times: [Double], cap: Int = recentEventCap) -> [Double]? {
        guard !times.isEmpty else { return nil }
        let sorted = times.sorted()
        return sorted.count > cap ? Array(sorted.suffix(cap)) : sorted
    }

    static func trimmedTools(_ tools: [MonitorAgentToolEvent], cap: Int = recentToolCap) -> [MonitorAgentToolEvent]? {
        guard !tools.isEmpty else { return nil }
        let sorted = tools.sorted { $0.at < $1.at }
        return sorted.count > cap ? Array(sorted.suffix(cap)) : sorted
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
