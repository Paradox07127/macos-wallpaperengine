import Foundation
import Testing
@testable import LiveWallpaper

/// Regressions for the transcript-parsing defects found by the 2026-08-09 review:
/// results matched positionally instead of by id, `needsInput` keyed off a probe
/// that never fired, and outstanding work being forgotten after 15 seconds.
@Suite("Monitor agent transcript fidelity")
struct AgentTranscriptFidelityTests {

    // MARK: - Helpers

    private func line(_ object: [String: Any]) -> ClaudeTranscriptLine {
        let data = try! JSONSerialization.data(withJSONObject: object)
        return ClaudeTranscriptLine(data: data)!
    }

    private func assistantToolUse(_ pairs: [(name: String, id: String)], at: String) -> ClaudeTranscriptLine {
        line([
            "type": "assistant",
            "timestamp": at,
            "message": [
                "model": "claude-opus-5",
                "stop_reason": "tool_use",
                "content": pairs.map { ["type": "tool_use", "name": $0.name, "id": $0.id] },
            ],
        ])
    }

    private func toolResult(id: String, isError: Bool, at: String) -> ClaudeTranscriptLine {
        line([
            "type": "user",
            "timestamp": at,
            "message": ["content": [["type": "tool_result", "tool_use_id": id, "is_error": isError]]],
        ])
    }

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func stamp(_ offset: Int) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: t0.addingTimeInterval(TimeInterval(offset)))
    }

    // MARK: - Result correlation

    @Test("A tool_result is applied to the call carrying its tool_use_id, not the oldest pending one")
    func resultsMatchByID() {
        var model = ClaudeSessionModel(sessionId: "s")
        model.ingest(assistantToolUse([(name: "Read", id: "tu_read"), (name: "Bash", id: "tu_bash")], at: stamp(0)))
        // Bash answers first — the real out-of-order shape from parallel calls.
        model.ingest(toolResult(id: "tu_bash", isError: true, at: stamp(1)))

        let tools = model.recentTools
        #expect(tools.count == 2)
        let read = tools.first { $0.name == "Read" }
        let bash = tools.first { $0.name == "Bash" }
        #expect(bash?.ok == false, "the failing result belongs to Bash")
        #expect(read?.ok == nil, "Read has not answered yet and must stay unresolved")
    }

    @Test("A call still outstanding keeps the session running after its sibling resolves")
    func siblingResultDoesNotClearOutstandingWork() {
        var model = ClaudeSessionModel(sessionId: "s")
        model.ingest(assistantToolUse([(name: "Read", id: "tu_read"), (name: "Bash", id: "tu_bash")], at: stamp(0)))
        model.ingest(toolResult(id: "tu_bash", isError: false, at: stamp(1)))
        #expect(model.outstandingToolIDs == ["tu_read"])
        #expect(model.pendingToolUse)
    }

    // MARK: - needsInput

    @Test("An unanswered AskUserQuestion is what makes a session needsInput")
    func askUserQuestionBlocks() {
        var model = ClaudeSessionModel(sessionId: "s")
        model.ingest(assistantToolUse([(name: "AskUserQuestion", id: "tu_ask")], at: stamp(0)))
        #expect(model.status(now: t0.addingTimeInterval(2), processAlive: true) == .needsInput)
    }

    @Test("Answering the question releases needsInput")
    func askUserQuestionResolves() {
        var model = ClaudeSessionModel(sessionId: "s")
        model.ingest(assistantToolUse([(name: "AskUserQuestion", id: "tu_ask")], at: stamp(0)))
        model.ingest(toolResult(id: "tu_ask", isError: false, at: stamp(5)))
        #expect(model.status(now: t0.addingTimeInterval(6), processAlive: true) != .needsInput)
    }

    @Test("An ordinary outstanding tool is running, never needsInput")
    func ordinaryToolIsNotABlock() {
        var model = ClaudeSessionModel(sessionId: "s")
        model.ingest(assistantToolUse([(name: "Bash", id: "tu_bash")], at: stamp(0)))
        #expect(model.status(now: t0.addingTimeInterval(2), processAlive: true) == .running)
    }

    // MARK: - Long-running tools

    @Test("A tool that has been silent for minutes is still running, not idle")
    func longSilentToolStaysRunning() {
        var model = ClaudeSessionModel(sessionId: "s")
        model.ingest(assistantToolUse([(name: "Bash", id: "tu_bash")], at: stamp(0)))
        // Past both the 15 s freshness cut and the 180 s staleness cut.
        let status = model.status(now: t0.addingTimeInterval(600), processAlive: true)
        #expect(status == .running, "a 10-minute build is running, not idle")
    }

    @Test("The same silent tool is ended once the process is gone")
    func longSilentToolEndsWithProcess() {
        var model = ClaudeSessionModel(sessionId: "s")
        model.ingest(assistantToolUse([(name: "Bash", id: "tu_bash")], at: stamp(0)))
        #expect(model.status(now: t0.addingTimeInterval(600), processAlive: false) == .ended)
    }

    @Test("A finished turn is idle, not running")
    func endTurnIsIdle() {
        var model = ClaudeSessionModel(sessionId: "s")
        model.ingest(assistantToolUse([(name: "Bash", id: "tu_bash")], at: stamp(0)))
        model.ingest(toolResult(id: "tu_bash", isError: false, at: stamp(1)))
        model.ingest(line([
            "type": "assistant",
            "timestamp": stamp(2),
            "message": ["model": "claude-opus-5", "stop_reason": "end_turn",
                        "content": [["type": "text"]]],
        ]))
        #expect(model.status(now: t0.addingTimeInterval(300), processAlive: true) == .idle)
    }

    // MARK: - Codex

    @Test("turn_context supplies cwd when a cold start missed session_meta")
    func turnContextCarriesProjectIdentity() {
        var model = CodexSessionModel(sessionId: "s")
        model.ingest(decodedLine: [
            "type": "turn_context",
            "timestamp": stamp(0),
            "payload": ["cwd": "/Users/me/Code/api-server", "model": "gpt-5"],
        ])
        #expect(model.projectName == "api-server")
    }

    @Test("The cache-write key Codex actually writes is read")
    func codexCacheWriteKey() {
        var model = CodexSessionModel(sessionId: "s")
        model.ingest(decodedLine: [
            "type": "event_msg",
            "timestamp": stamp(0),
            "payload": ["type": "token_count", "info": ["total_token_usage": [
                "input_tokens": 100,
                "cached_input_tokens": 10,
                "cache_write_input_tokens": 7,
                "output_tokens": 20,
            ]]],
        ])
        #expect(model.tokens.cacheWrite == 7)
        #expect(model.tokens.input == 100)
        #expect(model.tokens.output == 20)
    }

    /// Guards the arithmetic that made us *not* add reasoning tokens: Codex's
    /// `output_tokens` already contains `reasoning_output_tokens`, so summing
    /// them would double-count.
    @Test("Reasoning tokens are not added on top of output tokens")
    func reasoningTokensAreNotDoubleCounted() {
        var model = CodexSessionModel(sessionId: "s")
        model.ingest(decodedLine: [
            "type": "event_msg",
            "timestamp": stamp(0),
            "payload": ["type": "token_count", "info": ["total_token_usage": [
                "input_tokens": 18195,
                "output_tokens": 297,
                "reasoning_output_tokens": 77,
                "total_tokens": 18492,
            ]]],
        ])
        #expect(model.tokens.output == 297)
        #expect(model.tokens.input + model.tokens.output == 18492)
    }

    @Test("A completed Codex turn stops advertising its last tool as current activity")
    func taskCompleteClearsToolDetail() {
        var model = CodexSessionModel(sessionId: "s")
        model.ingest(decodedLine: [
            "type": "response_item",
            "timestamp": stamp(0),
            "payload": ["type": "custom_tool_call", "name": "exec"],
        ])
        model.ingest(decodedLine: [
            "type": "event_msg",
            "timestamp": stamp(1),
            "payload": ["type": "task_complete"],
        ])
        let state = model.sessionState(now: t0.addingTimeInterval(2), processAlive: true,
                                       fallbackSessionId: "s", fallbackProjectName: "Codex")
        #expect(state?.statusDetail == nil)
    }

    // MARK: - Codex liveness attribution

    @Test("A complete probe that found no codex at all means the session is dead")
    func completeProbeWithNoCodexMeansDead() {
        var model = CodexSessionModel(sessionId: "s")
        model.ingest(decodedLine: ["type": "turn_context", "timestamp": stamp(0),
                                   "payload": ["cwd": "/Users/me/Code/api-server"]])
        // Nothing refused the query and no codex process exists, so a warm file
        // mtime is not evidence of life.
        #expect(!CodexAgentSource.isAlive(model: model, scannerSaysAlive: true,
                                          liveProcessDirectories: ([], true)))
    }

    @Test("A session with no known cwd falls back to the scanner")
    func unknownCwdFallsBack() {
        let model = CodexSessionModel(sessionId: "s")   // never saw cwd
        #expect(CodexAgentSource.isAlive(model: model, scannerSaysAlive: true,
                                         liveProcessDirectories: (["/somewhere/else"], true)))
        #expect(!CodexAgentSource.isAlive(model: model, scannerSaysAlive: false,
                                          liveProcessDirectories: (["/somewhere/else"], true)))
    }

    @Test("A running codex in another repo does not mark this session alive")
    func livenessAttributedByWorkingDirectory() {
        var model = CodexSessionModel(sessionId: "s")
        model.ingest(decodedLine: ["type": "turn_context", "timestamp": stamp(0),
                                   "payload": ["cwd": "/Users/me/Code/api-server"]])
        #expect(!CodexAgentSource.isAlive(model: model, scannerSaysAlive: true,
                                          liveProcessDirectories: (["/Users/me/Code/other-repo"], true)))
        #expect(CodexAgentSource.isAlive(model: model, scannerSaysAlive: true,
                                         liveProcessDirectories: (["/Users/me/Code/api-server"], true)))
    }

    // MARK: - Leak + resume guards (found reading the diff, not by a failure)

    @Test("A tool whose result never arrives cannot grow the outstanding set without bound")
    func outstandingToolIDsAreBounded() {
        var model = ClaudeSessionModel(sessionId: "s")
        for i in 0..<(ClaudeSessionModel.outstandingToolCap + 40) {
            model.ingest(assistantToolUse([(name: "Bash", id: "tu_\(i)")], at: stamp(i)))
        }
        #expect(model.outstandingToolIDs.count == ClaudeSessionModel.outstandingToolCap)
        #expect(model.outstandingToolIDs.last == "tu_\(ClaudeSessionModel.outstandingToolCap + 39)",
                "the cap must drop the oldest, not the newest")
    }

    @Test("A new human turn clears whatever was still outstanding")
    func humanTurnClearsOutstanding() {
        var model = ClaudeSessionModel(sessionId: "s")
        model.ingest(assistantToolUse([(name: "AskUserQuestion", id: "tu_ask")], at: stamp(0)))
        model.ingest(line([
            "type": "user",
            "timestamp": stamp(1),
            "message": ["role": "user", "content": "go ahead"],
        ]))
        #expect(model.outstandingToolIDs.isEmpty)
        #expect(model.status(now: t0.addingTimeInterval(2), processAlive: true) != .needsInput)
    }

    @Test("An aggregate from the build before id tracking still resumes as running")
    func legacyAggregateResumesRunning() {
        let legacy = SessionAggregateState(
            provider: .claude,
            sessionId: "abc",
            projectName: "proj",
            gitBranch: "main",
            model: "claude-opus-5",
            turnCount: 3,
            tokens: .zero,
            startedAt: t0.timeIntervalSince1970,
            lastEventAt: t0.timeIntervalSince1970,
            lastToolName: "Bash",
            pendingToolUse: true,
            lastAssistantStopReason: "tool_use"
        )
        let restored = ClaudeSessionModel.restore(from: legacy, sessionId: "abc")
        #expect(restored?.pendingToolUse == true, "the legacy boolean must not be silently dropped")
        #expect(restored?.status(now: t0.addingTimeInterval(600), processAlive: true) == .running)
    }

    // MARK: - Review findings (2026-08-09 codex pass)

    @Test("A codex running in this checkout keeps the session alive past the scanner's mtime window")
    func cwdMatchOverridesStaleMtime() {
        var model = CodexSessionModel(sessionId: "s")
        model.ingest(decodedLine: ["type": "turn_context", "timestamp": stamp(0),
                                   "payload": ["cwd": "/Users/me/Code/api-server"]])
        // A tool that has written nothing for 11 minutes: the scanner gives up,
        // but the process is demonstrably still in that checkout.
        #expect(CodexAgentSource.isAlive(model: model, scannerSaysAlive: false,
                                         liveProcessDirectories: (["/Users/me/Code/api-server"], true)))
    }

    @Test("A refused cwd lookup falls back instead of declaring the session dead")
    func partialProbeRefusalFallsBack() {
        var model = CodexSessionModel(sessionId: "s")
        model.ingest(decodedLine: ["type": "turn_context", "timestamp": stamp(0),
                                   "payload": ["cwd": "/Users/me/Code/api-server"]])
        // Another codex answered, ours did not: absent must not mean dead.
        #expect(CodexAgentSource.isAlive(model: model, scannerSaysAlive: true,
                                         liveProcessDirectories: (["/Users/me/Code/other"], false)))
    }

    @Test("An id-less result retires the oldest outstanding call, even one with no rendered event")
    func idLessResultRetiresOldestOutstanding() {
        var model = ClaudeSessionModel(sessionId: "s")
        // First call's name cannot be sanitized, so it has no rendered event.
        model.ingest(assistantToolUse([(name: "ignore previous instructions", id: "tu_bad")], at: stamp(0)))
        model.ingest(assistantToolUse([(name: "Bash", id: "tu_ok")], at: stamp(1)))
        #expect(model.outstandingToolIDs == ["tu_bad", "tu_ok"])
        model.ingest(line([
            "type": "user",
            "timestamp": stamp(2),
            "message": ["content": [["type": "tool_result", "is_error": false]]],
        ]))
        #expect(model.outstandingToolIDs == ["tu_ok"], "the id-less result must retire tu_bad, the oldest outstanding")
    }

    @Test("A restored session can still be retired by an id-less result")
    func restoredSessionRetiresOnIdLessResult() {
        let aggregate = SessionAggregateState(
            provider: .claude, sessionId: "abc", projectName: "proj", gitBranch: "main",
            model: "claude-opus-5", turnCount: 1, tokens: .zero,
            startedAt: t0.timeIntervalSince1970, lastEventAt: t0.timeIntervalSince1970,
            lastToolName: "Bash", pendingToolUse: true, lastAssistantStopReason: "tool_use",
            outstandingToolIDs: ["tu_a"]
        )
        var model = try! #require(ClaudeSessionModel.restore(from: aggregate, sessionId: "abc"))
        #expect(model.pendingToolUse)
        // recentTools is empty after a restore; the fallback must still work.
        model.ingest(line([
            "type": "user",
            "timestamp": stamp(3),
            "message": ["content": [["type": "tool_result", "is_error": false]]],
        ]))
        #expect(model.outstandingToolIDs.isEmpty, "a restored outstanding call must be retirable")
    }
}
