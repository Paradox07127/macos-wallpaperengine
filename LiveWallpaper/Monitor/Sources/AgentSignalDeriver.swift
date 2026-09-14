import Foundation

enum AgentSignalDeriver {
    static let recentEventCap = 60
    static let recentToolCap = 8

    /// A warning requires forty calls in ten minutes plus at least three failed results; repeated names alone are ordinary shell-heavy work.
    static let toolLoopRun = 40
    /// Events kept per session for the detector — enough to see a whole run.
    /// Separate from `recentToolCap`, which is the display tail.
    static let toolLoopBuffer = 48
    static let toolLoopWindow: TimeInterval = 10 * 60

    /// A running+alive session with no new event past this is "stale".
    static let staleAfter: TimeInterval = 15 * 60

    static let toolNameMaxLength = 64

    private static let toolNameAllowed = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.:-"
    )

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
        guard time.isFinite, times.last != time else { return }
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
        if status == .running, isToolLoop(recentTools),
           let last = recentTools.last, now - last.at <= toolLoopWindow {
            return "toolLoop"
        }
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
        return tail.allSatisfy { $0.name == first.name } && tail.filter { $0.ok == false }.count >= 3
    }

    static func displayMetadata(_ value: String) -> String? {
        let clean = value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        let text = String(String.UnicodeScalarView(clean)).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : String(text.prefix(96))
    }
}

enum MonitorWorktree {
    static func name(fromCwd cwd: String?) -> String? {
        guard let cwd, !cwd.isEmpty else { return nil }
        let components = (cwd as NSString).pathComponents
        // Find the ".../.claude/worktrees/<name>/..." segment and take the segment immediately after "worktrees".
        guard let worktreesIndex = components.firstIndex(where: { $0 == "worktrees" }),
              worktreesIndex >= 1, [".claude", ".codex"].contains(components[worktreesIndex - 1]),
              worktreesIndex + 1 < components.count else {
            return nil
        }
        let name = components[worktreesIndex + 1]
        return name.isEmpty || name == "/" ? nil : name
    }
}

struct MonitorAgentWaitTracker {
    private var waitSince: [String: Double] = [:]

    mutating func waitSince(
        sessionID: String,
        status: MonitorAgentStatus,
        eventTime: Double
    ) -> Double? {
        if status == .needsInput {
            if let existing = waitSince[sessionID] {
                return existing
            }
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
