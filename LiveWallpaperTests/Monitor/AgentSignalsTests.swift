import Foundation
import Testing
@testable import LiveWallpaper

@Suite("Monitor agent-session signals")
struct AgentSignalsTests {

    private func run(_ name: String, _ count: Int, spacing: Double = 5, base: Double = 1_000) -> [MonitorAgentToolEvent] {
        (0..<count).map { MonitorAgentToolEvent(name: name, at: base + Double($0) * spacing, ok: true) }
    }

    @Test("toolLoop fires on a full run of same-name tools within 10 min")
    func toolLoopDetected() {
        let tools = run("Bash", AgentSignalDeriver.toolLoopRun, spacing: 5)
        #expect(AgentSignalDeriver.isToolLoop(tools))
        let warning = AgentSignalDeriver.warning(
            recentTools: tools, status: .running, processAlive: true,
            lastEventAt: 1_200, now: 1_205
        )
        #expect(warning == "toolLoop")
    }

    /// The threshold used to be 8, which is normal work, not a loop: 23 of the
    /// 58 most recent local sessions tripped it, one of them on eight `Bash`
    /// calls inside 61 seconds. Anything at or under a routine burst has to
    /// stay quiet or the widget's warn chip means nothing.
    @Test("a routine burst of identical tools is not a loop")
    func routineBurstIsNotALoop() {
        #expect(!AgentSignalDeriver.isToolLoop(run("Bash", 8, spacing: 7)))
        #expect(!AgentSignalDeriver.isToolLoop(run("Read", 12, spacing: 3)))
        #expect(!AgentSignalDeriver.isToolLoop(run("Bash", AgentSignalDeriver.toolLoopRun - 1, spacing: 5)))
    }

    @Test("no loop when names differ or the window is too wide")
    func toolLoopNegatives() {
        let n = AgentSignalDeriver.toolLoopRun
        let mixed = (0..<n).map {
            MonitorAgentToolEvent(name: $0 % 2 == 0 ? "Bash" : "Read", at: 1_000 + Double($0), ok: true)
        }
        #expect(!AgentSignalDeriver.isToolLoop(mixed))
        // Same run, spread past the 10-minute window.
        #expect(!AgentSignalDeriver.isToolLoop(run("Bash", n, spacing: 120)))
    }

    /// The detector can only see what the models keep, so the buffer has to be
    /// able to hold a whole run — a cap below `toolLoopRun` would make the
    /// warning unreachable rather than rare.
    @Test("the retained buffer can hold a full run")
    func bufferHoldsAFullRun() {
        #expect(AgentSignalDeriver.toolLoopBuffer >= AgentSignalDeriver.toolLoopRun)
    }

    @Test("stale fires only past the silence window")
    func staleDetected() {
        let now = 10_000.0
        func warn(silentFor seconds: Double) -> String? {
            AgentSignalDeriver.warning(
                recentTools: [], status: .running, processAlive: true,
                lastEventAt: now - seconds, now: now
            )
        }
        #expect(warn(silentFor: AgentSignalDeriver.staleAfter + 60) == "stale")
        // A long build, a full test run, or a fan-out to review subagents all
        // sit on one pending tool call for minutes with nothing to write.
        #expect(warn(silentFor: 9 * 60) == nil)
    }

    @Test("no stale when idle, dead, or recently active; loop precedes stale")
    func staleNegativesAndPrecedence() {
        let now = 10_000.0
        #expect(AgentSignalDeriver.warning(
            recentTools: [], status: .idle, processAlive: true,
            lastEventAt: now - AgentSignalDeriver.staleAfter - 60, now: now
        ) == nil)
        #expect(AgentSignalDeriver.warning(
            recentTools: [], status: .running, processAlive: true, lastEventAt: now - 60, now: now
        ) == nil)
        #expect(AgentSignalDeriver.warning(
            recentTools: [], status: .running, processAlive: false,
            lastEventAt: now - AgentSignalDeriver.staleAfter - 60, now: now
        ) == nil)
        let loop = run("Bash", AgentSignalDeriver.toolLoopRun, spacing: 5, base: now - 300)
        #expect(AgentSignalDeriver.warning(
            recentTools: loop, status: .running, processAlive: true,
            lastEventAt: now - AgentSignalDeriver.staleAfter - 60, now: now
        ) == "toolLoop")
    }

    @Test("waitSince stamps flip into needsInput, carries, then clears")
    func waitSinceLifecycle() {
        var tracker = MonitorAgentWaitTracker()
        #expect(tracker.waitSince(sessionID: "s", status: .running, eventTime: 100) == nil)
        #expect(tracker.waitSince(sessionID: "s", status: .needsInput, eventTime: 200) == 200)
        #expect(tracker.waitSince(sessionID: "s", status: .needsInput, eventTime: 260) == 200)
        #expect(tracker.waitSince(sessionID: "s", status: .running, eventTime: 300) == nil)
        #expect(tracker.waitSince(sessionID: "s", status: .needsInput, eventTime: 400) == 400)
    }

    @Test("waitTracker forgets sessions dropped from the live set")
    func waitTrackerRetention() {
        var tracker = MonitorAgentWaitTracker()
        _ = tracker.waitSince(sessionID: "a", status: .needsInput, eventTime: 100)
        _ = tracker.waitSince(sessionID: "b", status: .needsInput, eventTime: 100)
        tracker.retainOnly(["a"])
        #expect(tracker.waitSince(sessionID: "b", status: .needsInput, eventTime: 999) == 999)
        #expect(tracker.waitSince(sessionID: "a", status: .needsInput, eventTime: 999) == 100)
    }

    @Test("recentTools marks ok=false on the paired tool_result is_error")
    func recentToolsErrorPairing() {
        var model = ClaudeSessionModel(sessionId: "s1")
        let base = Date(timeIntervalSince1970: 1_783_000_000)
        model.ingest(assistant(tool: "Bash", at: base, input: 10, cacheRead: 0))
        model.ingest(toolResult(at: base.addingTimeInterval(1), isError: true))
        model.ingest(assistant(tool: "Read", at: base.addingTimeInterval(2), input: 10, cacheRead: 0))
        model.ingest(toolResult(at: base.addingTimeInterval(3), isError: false))

        let snap = model.snapshot(now: base.addingTimeInterval(4), processAlive: true)
        let tools = snap.recentTools ?? []
        #expect(tools.count == 2)
        #expect(tools[0].name == "Bash")
        #expect(tools[0].ok == false)
        #expect(tools[1].name == "Read")
        #expect(tools[1].ok == true)
    }

    @Test("recentEventTimes capped at 60, ascending")
    func recentEventTimesCap() {
        var model = ClaudeSessionModel(sessionId: "s1")
        let base = Date(timeIntervalSince1970: 1_783_000_000)
        for i in 0..<100 {
            model.ingest(assistant(tool: "Bash", at: base.addingTimeInterval(Double(i)), input: 1, cacheRead: 0))
        }
        let snap = model.snapshot(now: base.addingTimeInterval(200), processAlive: true)
        let times = snap.recentEventTimes ?? []
        #expect(times.count == 60)
        #expect(times == times.sorted())
        #expect(times.last == base.addingTimeInterval(99).timeIntervalSince1970)
    }

    @Test("recentTools surfaced tail capped at 8")
    func recentToolsCap() {
        var model = ClaudeSessionModel(sessionId: "s1")
        let base = Date(timeIntervalSince1970: 1_783_000_000)
        for i in 0..<20 {
            model.ingest(assistant(tool: "Bash", at: base.addingTimeInterval(Double(i)), input: 1, cacheRead: 0))
        }
        let snap = model.snapshot(now: base.addingTimeInterval(30), processAlive: true)
        #expect((snap.recentTools?.count ?? 0) == 8)
    }

    @Test("worktreeName extracts the segment after .claude/worktrees, else nil")
    func worktreeExtraction() {
        #expect(MonitorWorktree.name(fromCwd: "/Users/me/proj/.claude/worktrees/feature-x") == "feature-x")
        #expect(MonitorWorktree.name(fromCwd: "/Users/me/proj/.claude/worktrees/feature-x/src/deep") == "feature-x")
        #expect(MonitorWorktree.name(fromCwd: "/Users/me/proj/src") == nil)
        #expect(MonitorWorktree.name(fromCwd: "/Users/me/worktrees/x") == nil)
        #expect(MonitorWorktree.name(fromCwd: nil) == nil)
    }

    @Test("Claude snapshot carries worktreeName from cwd metadata")
    func claudeSnapshotWorktree() {
        var model = ClaudeSessionModel(sessionId: "s1")
        let base = Date(timeIntervalSince1970: 1_783_000_000)
        model.ingest(line([
            "type": "assistant", "isSidechain": false, "timestamp": iso(base),
            "sessionId": "s1", "cwd": "/Users/me/LiveWallpaper/.claude/worktrees/monitor-v2",
            "message": [
                "role": "assistant", "model": "claude-opus-4-8", "stop_reason": "tool_use",
                "content": [["type": "tool_use", "name": "Bash"]],
                "usage": ["input_tokens": 10, "output_tokens": 1, "cache_read_input_tokens": 0, "cache_creation_input_tokens": 0]
            ]
        ]))
        let snap = model.snapshot(now: base.addingTimeInterval(1), processAlive: true)
        #expect(snap.worktreeName == "monitor-v2")
    }

    private func line(_ dict: [String: Any]) -> ClaudeTranscriptLine {
        ClaudeTranscriptLine(data: try! JSONSerialization.data(withJSONObject: dict))!
    }

    private func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    private func assistant(tool: String, at date: Date, input: Int, cacheRead: Int, model: String = "claude-opus-4-8") -> ClaudeTranscriptLine {
        line([
            "type": "assistant", "isSidechain": false, "timestamp": iso(date),
            "sessionId": "s1", "cwd": "/Users/me/proj",
            "message": [
                "role": "assistant", "model": model, "stop_reason": "tool_use",
                "content": [["type": "tool_use", "name": tool]],
                "usage": ["input_tokens": input, "output_tokens": 5,
                          "cache_read_input_tokens": cacheRead, "cache_creation_input_tokens": 0]
            ]
        ])
    }

    private func toolResult(at date: Date, isError: Bool) -> ClaudeTranscriptLine {
        line([
            "type": "user", "isSidechain": false, "timestamp": iso(date), "sessionId": "s1",
            "message": ["role": "user", "content": [["type": "tool_result", "content": "redacted", "is_error": isError]]]
        ])
    }
}
