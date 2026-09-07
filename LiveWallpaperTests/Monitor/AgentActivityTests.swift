import Foundation
@testable import LiveWallpaper
import Testing

@Suite("Agent activity accuracy")
struct AgentActivityTests {
    private func codex(_ model: inout CodexSessionModel, _ type: String, _ payload: [String: Any], at time: Double) {
        model.ingest(decodedLine: ["type": type, "payload": payload,
                                   "timestamp": Date(timeIntervalSince1970: time).ISO8601Format()])
    }

    @Test("Repeated usage blocks are replaced, including after a durable checkpoint")
    func usageCorrectionsSurviveRestore() throws {
        var model = ClaudeSessionModel(sessionId: "fixture")
        func block(_ output: Int) -> ClaudeTranscriptLine {
            ClaudeTranscriptLine(dict: ["type": "assistant", "timestamp": "2026-09-01T00:00:00Z",
                                        "message": ["id": "message-A", "usage": ["input_tokens": 10, "output_tokens": output],
                                                    "content": [["type": "text", "text": "private fixture"]]]])
        }
        model.ingest(block(20))
        model.ingest(block(20))
        #expect(model.tokens.total == 30)
        let bytes = try JSONEncoder().encode(model.snapshotState())
        #expect(!(String(data: bytes, encoding: .utf8) ?? "").contains("private fixture"))
        #expect(!(String(data: bytes, encoding: .utf8) ?? "").contains("message-A"))
        let state = try JSONDecoder().decode(SessionAggregateState.self, from: bytes)
        var restored = try #require(ClaudeSessionModel.restore(from: state, sessionId: "fixture"))
        restored.ingest(block(25))
        #expect(restored.tokens.total == 35)
    }

    @Test("Metadata user records neither start turns nor clear pending questions")
    func metadataDoesNotAnswerQuestions() throws {
        var model = ClaudeSessionModel(sessionId: "fixture")
        model.ingest(ClaudeTranscriptLine(dict: ["type": "assistant", "timestamp": "2026-09-01T00:00:00Z",
                                                 "message": ["content": [["type": "tool_use", "id": "ask", "name": "AskUserQuestion"]]]]))
        let before = model.lastEventAt
        model.ingest(ClaudeTranscriptLine(dict: ["type": "user", "isMeta": true,
                                                 "timestamp": "2026-09-01T00:00:10Z", "message": ["content": "private attachment"]]))
        #expect(model.turnCount == 0)
        #expect(model.lastEventAt == before)
        #expect(try model.status(now: #require(before), processAlive: true) == .needsInput)
    }

    @Test("Codex structured command results expose duration and failure without arguments")
    func structuredCommandResults() {
        var model = CodexSessionModel()
        codex(&model, "event_msg", ["type": "task_started", "turn_id": "turn"], at: 10)
        codex(&model, "response_item", ["type": "function_call", "name": "exec_command", "call_id": "call",
                                        "arguments": "private command"], at: 11)
        codex(&model, "event_msg", ["type": "item_completed", "started_at_ms": 11000, "completed_at_ms": 16000,
                                    "item": ["type": "CommandExecution", "id": "call", "exit_code": 1,
                                             "status": "failed", "command": "private command", "stdout": "private result"]], at: 16)
        #expect(model.recentTools.count == 1)
        #expect(model.recentTools.first?.name == "shell")
        #expect(model.recentTools.first?.ok == false)
        #expect(model.recentTools.first?.durationSeconds == 5)
        #expect(model.lastToolName == nil)
        #expect(model.activity.phase == .responding)
    }

    @Test("An ordinary output cannot erase an authoritative structured failure")
    func structuredResultWins() {
        var state = AgentActivityState()
        state.beginTool(id: "a", name: "shell", at: 1)
        state.endTool(id: "a", at: 4, ok: false)
        state.endTool(id: "a", at: 5, ok: nil)
        #expect(state.tools.first?.ok == false)
        #expect(state.tools.first?.completedAt == 4)
    }

    @Test("A resumed session resets the turn clock and duplicate starts do not count twice")
    func currentTurnClock() {
        var model = CodexSessionModel()
        codex(&model, "event_msg", ["type": "task_started", "turn_id": "old"], at: 10)
        codex(&model, "event_msg", ["type": "task_complete"], at: 20)
        codex(&model, "event_msg", ["type": "task_started", "turn_id": "new"], at: 1000)
        codex(&model, "event_msg", ["type": "task_started", "turn_id": "new"], at: 1000)
        #expect(model.turnCount == 2)
        #expect(model.startedAt?.timeIntervalSince1970 == 10)
        #expect(model.activity.turnStartedAt == 1000)
    }

    @Test("Bookkeeping and unknown records cannot keep a completed task fresh")
    func bookkeepingIsNotActivity() {
        var model = CodexSessionModel()
        codex(&model, "event_msg", ["type": "task_complete"], at: 10)
        codex(&model, "event_msg", ["type": "token_count", "info": ["total_token_usage": ["input_tokens": 12]]], at: 50)
        codex(&model, "world_state", ["state": "private"], at: 100)
        #expect(model.lastEventAt?.timeIntervalSince1970 == 10)
        #expect(model.recentEventTimes == [10])
        #expect(model.tokens.input == 12)
    }

    @Test("Injected instructions and reasoning summaries are not session activity")
    func injectedInstructionsAreQuiet() {
        var model = CodexSessionModel()
        codex(&model, "event_msg", ["type": "task_complete"], at: 10)
        for role in ["system", "developer"] {
            codex(&model, "response_item", ["type": "message", "role": role], at: 100)
        }
        codex(&model, "event_msg", ["type": "item_completed", "item": ["id": "r", "type": "Reasoning"]], at: 110)
        #expect(model.lastEventAt?.timeIntervalSince1970 == 10)
        #expect(model.activity.phase == .completed)
        #expect(model.recentTools.isEmpty)
    }

    @Test("Session trees preserve children and recover missing parents and cycles")
    func sessionTree() {
        func session(_ id: String, parent: String? = nil) -> MonitorAgentSessionState {
            var result = MonitorAgentSessionState(id: id, provider: .codex, projectName: id,
                                                  status: .running, lastEventAt: 0, processAlive: true)
            result.parentSessionID = parent
            return result
        }
        let nodes = AgentSessionTreeNode.build([session("root"), session("child", parent: "root"),
                                                session("a", parent: "b"), session("b", parent: "a"),
                                                session("orphan", parent: "missing"), session("root")])
        func flatten(_ nodes: [AgentSessionTreeNode]) -> [String] {
            nodes.flatMap { [$0.id] + flatten($0.children ?? []) }
        }
        #expect(nodes.first?.children?.first?.id == "child")
        #expect(Set(flatten(nodes)) == ["root", "child", "a", "b", "orphan"])
        #expect(flatten(nodes).count == 5)
    }

    @Test("Parallel questions stay waiting until the matching question is answered")
    func parallelQuestions() {
        var activity = AgentActivityState()
        activity.beginTool(id: "ask", name: "request_user_input", at: 1)
        activity.beginTool(id: "shell", name: "shell", at: 2)
        activity.endTool(id: "shell", at: 3, ok: true)
        #expect(activity.phase == .waitingForInput)
        activity.endTool(id: "ask", at: 4, ok: nil)
        #expect(activity.phase == .responding)
    }

    @Test("Waiting for a script is distinct from waiting for child agents")
    func waitToolSemantics() {
        var activity = AgentActivityState()
        activity.beginTool(id: "script", name: "functions.wait", at: 1)
        #expect(activity.phase == .executing)
        activity.endTool(id: "script", at: 2, ok: nil)
        activity.beginTool(id: "agents", name: "wait_agent", at: 3)
        activity.beginTool(id: "shell", name: "shell", at: 4)
        activity.endTool(id: "shell", at: 5, ok: true)
        #expect(activity.phase == .waitingForAgents)
    }

    @Test("Polling backs off while quiet and drains backlog without a busy wait on partial lines")
    func adaptivePolling() throws {
        var policy = AgentPollingPolicy()
        #expect(policy.interval(changed: true, working: true) == 0.75)
        var interval = 0.0
        for _ in 0 ..< 10 {
            interval = policy.interval(changed: false, working: false)
        }
        #expect(interval == 10)
        #expect(policy.interval(changed: false, working: true, catchingUp: true) == 0.25)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("{\"type\":".utf8).write(to: url)
        let reader = JSONLTailReader(url: url, resumeFrom: nil)
        #expect(try reader.poll().newLines.isEmpty)
        #expect(!reader.hasUnreadBytes)
    }

    @Test("Successful wrapper runs are not classified as a tool loop")
    func successfulWrappersAreQuiet() {
        let tools = (0 ..< 48).map { MonitorAgentToolEvent(name: "exec", at: Double($0), ok: true) }
        #expect(!AgentSignalDeriver.isToolLoop(tools))
    }

    @Test("Provider total semantics include Claude cache categories only once")
    func providerTokenSemantics() {
        var state = MonitorAgentSessionState(id: "s", provider: .claude, projectName: "p",
                                             status: .idle, lastEventAt: 0, processAlive: false, tokens: .init(input: 10, output: 5, cacheRead: 20, cacheWrite: 3))
        #expect(state.totalTokenCount == 38)
        state.provider = .codex
        #expect(state.totalTokenCount == 15)
    }

    @Test("Known old date shards are found when a session is resumed")
    func resumedOldShard() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("sessions/2020/01/01")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("rollout-old.jsonl")
        try Data("{}\n".utf8).write(to: url)
        let history = AgentHistoryDiscovery(root: root.appendingPathComponent("sessions"))
        let known = history.scan(now: Date())
        let scanner = CodexSessionScanner(rootURL: root, processProbe: { false })
        #expect(try scanner.scan(knownURLs: known).map(\.url) == [url])
    }
}
