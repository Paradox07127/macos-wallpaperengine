import Testing
import Foundation
import os
@testable import LiveWallpaper

@Suite("System metrics source")
struct SystemMetricsSourceTests {
    private actor MockSink: MonitorSnapshotSink {
        private(set) var lastSystem: MonitorSystemSnapshot?
        private(set) var systemUpdateCount = 0
        private(set) var lastHealth: MonitorSourceHealth?

        func updateSystem(_ snapshot: MonitorSystemSnapshot) async {
            lastSystem = snapshot
            systemUpdateCount += 1
        }
        func updateAgents(sourceID: String, sessions: [MonitorAgentSessionState]) async {}
        func updateHealth(_ health: MonitorSourceHealth) async { lastHealth = health }
        func updateNowPlaying(_ state: MonitorNowPlayingState?) async {}

        func system() -> MonitorSystemSnapshot? { lastSystem }
        func health() -> MonitorSourceHealth? { lastHealth }
        func count() -> Int { systemUpdateCount }
    }

    @Test("Source emits a plausible system snapshot", .timeLimit(.minutes(1)))
    func emitsSystemSnapshot() async {
        let sink = MockSink()
        let source = SystemMetricsSource(includeTopProcesses: false, interval: 0.5)

        await source.start(sink: sink)

        let deadline = Date().addingTimeInterval(3.0)
        while Date() < deadline {
            if await sink.count() >= 2 { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        await source.stop()

        guard let snapshot = await sink.system() else {
            Issue.record("no system snapshot arrived within the timeout")
            return
        }

        #expect(snapshot.memTotalBytes > 0)
        #expect(snapshot.memUsedBytes > 0)
        #expect(snapshot.cpuTotal >= 0)
        #expect(snapshot.cpuTotal <= 1)
        #expect(snapshot.loadAverage1 == snapshot.cpuLoadAvg?.first)

        let health = await sink.health()
        #expect(health?.sourceID == "system")
        #expect(health?.state == "ok")
    }

    @Test("Each published poll samples load averages exactly once", .timeLimit(.minutes(1)))
    func pollSamplesLoadAverageOnce() async {
        let sink = MockSink()
        let samplerCalls = OSAllocatedUnfairLock(initialState: 0)
        let source = SystemMetricsSource(
            includeTopProcesses: false,
            interval: 60,
            loadAverageSampler: {
                samplerCalls.withLock { $0 += 1 }
                return [1.25, 0.75, 0.5]
            }
        )

        await source.start(sink: sink)
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if await sink.count() >= 1 { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        await source.stop()

        let updateCount = await sink.count()
        let callCount = samplerCalls.withLock { $0 }
        #expect(updateCount == 1)
        #expect(callCount == updateCount)
        let snapshot = await sink.system()
        #expect(snapshot?.loadAverage1 == 1.25)
        #expect(snapshot?.cpuLoadAvg == [1.25, 0.75, 0.5])
    }

    private struct WalkRecord: Sendable {
        var calls = 0
        var intervals: [TimeInterval] = []
        var previousCounters: [[Int32: SystemMetricsSamplers.ProcessCPUCounters]] = []
    }

    private static let walkSamples = [
        MonitorProcessSample(name: "WalkFixture", cpuPercent: 42, memBytes: 1_024, pid: 7)
    ]

    private static func recordingWalkSampler(
        into record: OSAllocatedUnfairLock<WalkRecord>
    ) -> SystemMetricsSource.TopProcessesSampler {
        { previous, interval, _ in
            record.withLock {
                $0.calls += 1
                $0.intervals.append(interval)
                $0.previousCounters.append(previous)
            }
            return SystemMetricsSamplers.TopProcessesResult(
                samples: walkSamples,
                ioSamples: [],
                counters: [7: SystemMetricsSamplers.ProcessCPUCounters(totalTimeNanos: 123)]
            )
        }
    }

    private func quietOptions() -> SystemMetricsSource.Options {
        var options = SystemMetricsSource.Options.default
        options.topProcesses = true
        options.gpu = false
        options.accessories = false
        return options
    }

    @Test("The process walk runs on its own slower cadence, not every base tick", .timeLimit(.minutes(1)))
    func processWalkSkipsBaseTicks() async {
        let sink = MockSink()
        let record = OSAllocatedUnfairLock(initialState: WalkRecord())
        let source = SystemMetricsSource(
            options: quietOptions(),
            interval: 0.1,
            topProcessesSampler: Self.recordingWalkSampler(into: record)
        )

        await source.start(sink: sink)
        let deadline = Date().addingTimeInterval(3.0)
        while Date() < deadline {
            if await sink.count() >= 4 { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        await source.stop()

        let updateCount = await sink.count()
        let walkCalls = record.withLock { $0.calls }
        #expect(updateCount >= 4)
        // Default 5s wall-clock cadence vs a 0.1s base tick: only the first
        // tick may walk within this test's 3s window.
        #expect(walkCalls == 1)
        // Skipped ticks republish the cached list instead of dropping it.
        #expect(await sink.system()?.topProcesses == Self.walkSamples)
    }

    @Test("A walk after skipped ticks gets the elapsed time since the previous walk", .timeLimit(.minutes(1)))
    func processWalkIntervalSpansSkippedTicks() async {
        let sink = MockSink()
        let record = OSAllocatedUnfairLock(initialState: WalkRecord())
        let source = SystemMetricsSource(
            options: quietOptions(),
            interval: 0.05,
            topProcessSampleSeconds: 0.15,
            topProcessesSampler: Self.recordingWalkSampler(into: record)
        )

        await source.start(sink: sink)
        let deadline = Date().addingTimeInterval(3.0)
        while Date() < deadline {
            if record.withLock({ $0.calls }) >= 2 { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        await source.stop()

        let snapshot = record.withLock { $0 }
        guard snapshot.calls >= 2 else {
            Issue.record("second process walk never happened within the timeout")
            return
        }
        // CPU%/IO deltas divide by the span between walks, not the base tick —
        // a per-tick elapsed here would inflate CPU% by the skip factor.
        #expect(snapshot.intervals[1] >= 0.14)
        // Counter bookkeeping survives the skipped ticks.
        #expect(snapshot.previousCounters[1][7]?.totalTimeNanos == 123)
    }

    @Test("Stopping halts further updates")
    func stopHaltsUpdates() async {
        let sink = MockSink()
        let source = SystemMetricsSource(includeTopProcesses: false, interval: 0.3)

        await source.start(sink: sink)
        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline {
            if await sink.count() >= 1 { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        await source.stop()

        let countAfterStop = await sink.count()
        try? await Task.sleep(nanoseconds: 700_000_000)
        let countLater = await sink.count()

        #expect(countLater == countAfterStop)
    }
}
