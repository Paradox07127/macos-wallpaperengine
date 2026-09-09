import Foundation
@testable import LiveWallpaper
import Testing

@Suite("Monitor snapshot continuity")
struct SnapshotContinuityTests {
    private func session(_ provider: MonitorAgentProvider) -> MonitorAgentSessionState {
        MonitorAgentSessionState(id: provider.rawValue + ":fixture", provider: provider,
                                 projectName: "fixture", status: .running, lastEventAt: 100, processAlive: true)
    }

    @Test("A resumed hub replaces sources independently, including authoritative empty results")
    func seededHubReplacesPerSource() async {
        let broker = SnapshotBroker()
        let system = MonitorSystemSnapshot(cpuTotal: 0.4, sampledAt: 100)
        let seed = MonitorSnapshot(timestamp: 100, system: system, agents: [session(.claude), session(.codex)])
        let hub = DataHub(broker: broker, throttleInterval: 0, initialSnapshot: seed)
        #expect(broker.latest(after: 0)?.snapshot == seed)

        await hub.updateHealth(MonitorSourceHealth(sourceID: "codex", state: "ok", lastUpdateAt: 200))
        #expect(broker.latest(after: 0)?.snapshot.agents?.count == 2)
        #expect(broker.latest(after: 0)?.snapshot.system?.sampledAt == 100)
        await hub.updateAgents(sourceID: "codex", sessions: [])
        #expect(broker.latest(after: 0)?.snapshot.agents == [session(.claude)])
        await hub.updateSystem(MonitorSystemSnapshot(cpuTotal: 0.8, sampledAt: 201))
        #expect(broker.latest(after: 0)?.snapshot.system?.cpuTotal == 0.8)
        #expect(broker.latest(after: 0)?.snapshot.agents == [session(.claude)])
        await hub.stop()
    }

    @Test("Retiring a hub cancels trailing publishes and ignores late callbacks")
    func retiredWriterCannotOverwriteResume() async throws {
        let broker = SnapshotBroker()
        let old = DataHub(broker: broker, throttleInterval: 0.03)
        await old.updateSystem(MonitorSystemSnapshot(cpuTotal: 0.1))
        await old.updateSystem(MonitorSystemSnapshot(cpuTotal: 0.2))
        await old.stop()
        let current = DataHub(broker: broker, throttleInterval: 0)
        await current.updateSystem(MonitorSystemSnapshot(cpuTotal: 0.9))
        let generation = broker.currentGeneration
        await old.updateSystem(MonitorSystemSnapshot(cpuTotal: 0.3))
        try await Task.sleep(for: .milliseconds(80))
        #expect(broker.currentGeneration == generation)
        #expect(broker.latest(after: 0)?.snapshot.system?.cpuTotal == 0.9)
        await current.stop()
    }

    @Test("Disabled modules and changed roots are removed from the retained frame")
    func retainedFrameHonoursConfiguration() {
        let old = MonitorRuntimeOptions(system: true, agents: true, claudeRoot: URL(fileURLWithPath: "/fixture/a"))
        var next = old
        next.system = false
        next.claudeRoot = URL(fileURLWithPath: "/fixture/b")
        let seed = MonitorSnapshot(timestamp: 100, system: MonitorSystemSnapshot(cpuTotal: 0.4),
                                   agents: [session(.claude), session(.codex)])
        let filtered = Runtime.retainedSnapshot(seed, previous: old, next: next)
        #expect(filtered?.system == nil)
        #expect(filtered?.agents == [session(.codex)])
        #expect(filtered?.timestamp == 100)
        next.agents = false
        #expect(Runtime.retainedSnapshot(seed, previous: old, next: next)?.agents == nil)
    }

    @Test("Repeated pause and resume retain data while still stopping the producer")
    func pauseResumeKeepsFrame() async {
        let source = ContinuitySource(initial: session(.codex))
        let runtime = makeRuntime(source: source)
        let lease = runtime.makeLeaseSlot().acquire(options: options)
        await lease.waitUntilSettled()
        await waitForInitialAgents(runtime.broker)
        #expect(runtime.broker.latest(after: 0)?.snapshot.agents?.count == 1)
        for _ in 0 ..< 5 {
            await lease.setPaused(true).value
            #expect(await runtime.debugActiveSourceCount == 0)
            #expect(runtime.broker.latest(after: 0)?.snapshot.agents?.count == 1)
            await lease.setPaused(false).value
            #expect(await runtime.debugActiveSourceCount == 1)
            #expect(runtime.broker.latest(after: 0)?.snapshot.agents?.count == 1)
        }
        await lease.setPaused(true).value
        await lease.release().value
        #expect(runtime.broker.latest(after: 0) == nil)
    }

    @Test("Explicit source refresh invalidates both visible and paused display caches", arguments: [true, false])
    func grantRefreshInvalidatesFrame(paused: Bool) async {
        let source = ContinuitySource(initial: session(.codex))
        let runtime = makeRuntime(source: source)
        let lease = runtime.makeLeaseSlot().acquire(options: options)
        await lease.waitUntilSettled()
        await waitForInitialAgents(runtime.broker)
        await lease.setPaused(paused).value
        #expect(runtime.broker.latest(after: 0)?.snapshot.agents?.count == 1)
        await runtime.refreshSources()
        #expect(runtime.broker.latest(after: 0)?.snapshot.agents == nil)
        if paused {
            #expect(runtime.broker.latest(after: 0) == nil)
        }
        await lease.setPaused(false).value
        #expect(runtime.broker.latest(after: 0)?.snapshot.agents == nil)
        await lease.release().value
    }

    private func waitForInitialAgents(_ broker: SnapshotBroker) async {
        let deadline = Date().addingTimeInterval(2)
        while broker.latest(after: 0)?.snapshot.agents?.count != 1, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private var options: MonitorRuntimeOptions {
        MonitorRuntimeOptions(system: false, agents: true, activeWidgetKinds: [.fleet])
    }

    private func makeRuntime(source: ContinuitySource) -> Runtime {
        Runtime(grants: MonitorGrantAccess(resolveRoots: {
            (claude: URL(fileURLWithPath: "/fixture/claude"), codex: URL(fileURLWithPath: "/fixture/codex"))
        }, release: {}), sourceFactories: [{ _ in [source] }])
    }
}

private actor ContinuitySource: MonitorDataSource {
    nonisolated let sourceID = "codex"
    private let initial: MonitorAgentSessionState
    private var starts = 0

    init(initial: MonitorAgentSessionState) {
        self.initial = initial
    }

    func start(sink: any MonitorSnapshotSink) async {
        starts += 1
        if starts == 1 {
            await sink.updateAgents(sourceID: sourceID, sessions: [initial])
        } else {
            // The source has restarted but its first new data is not ready yet.
            await sink.updateHealth(MonitorSourceHealth(sourceID: sourceID, state: "ok", lastUpdateAt: 200))
        }
    }

    func stop() async {}
}
