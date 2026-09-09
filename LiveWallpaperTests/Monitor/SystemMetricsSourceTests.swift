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
            if await sink.count() >= 2 {
                break
            }
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

    /// The wire still carries a placeholder `0` for a group nobody asked for;
    /// only `metricSamples` distinguishes it from an idle disk. The history has
    /// to read that provenance, or the chart draws a confident zero line.
    @Test("An undemanded group is published unavailable and lands in the history as absent",
          .timeLimit(.minutes(1)))
    @MainActor
    func undemandedGroupReachesHistoryAsAbsent() async {
        let sink = MockSink()
        var options = SystemMetricsSource.Options.default
        options.disk = false
        let source = SystemMetricsSource(options: options, interval: 0.5)

        await source.start(sink: sink)
        // Two polls: a CPU rate needs a previous tick, so the very first frame
        // legitimately has no CPU reading either.
        let deadline = Date().addingTimeInterval(3.0)
        while Date() < deadline {
            if await sink.count() >= 2 {
                break
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        await source.stop()

        guard let system = await sink.system() else {
            Issue.record("no system snapshot arrived within the timeout")
            return
        }
        #expect(system.diskReadBytesPerSec == 0)
        #expect(system.metricSamples?["disk"]?.available == false)
        #expect(system.metricSamples?["cpu"]?.available == true)

        var snapshot = MonitorSnapshot()
        snapshot.timestamp = system.sampledAt ?? 1
        snapshot.system = system
        let store = MonitorHistoryStore()
        store.ingest(snapshot)

        #expect(store.current.diskRead == [nil])
        #expect(store.current.cpuTotal == [system.cpuTotal])
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

    /// A rebuilt pipeline hands the board a brand-new source, and CPU, network
    /// and disk each report `available: false` on a tick with no previous
    /// counters to subtract. Every time an occluded board came back, that made
    /// the first published tick read "readings unavailable" for a whole
    /// interval before the real numbers arrived. `primeDeltaBaselines` is what
    /// keeps that first tick real; drop it and this goes red.
    @Test("The first published tick already carries a real CPU reading", .timeLimit(.minutes(1)))
    func firstTickCarriesDeltaBaselines() async {
        let sink = MockSink()
        // Wide enough that only the priming gap, never a second tick, can land
        // inside the wait below — the assertion has to judge the FIRST tick.
        let source = SystemMetricsSource(includeTopProcesses: false, interval: 5.0)

        await source.start(sink: sink)

        let deadline = Date().addingTimeInterval(3.0)
        while Date() < deadline, await sink.count() == 0 {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        await source.stop()

        let ticks = await sink.count()
        guard let snapshot = await sink.system() else {
            Issue.record("no system snapshot arrived within the timeout")
            return
        }

        #expect(ticks == 1)
        #expect(snapshot.metricSamples?["cpu"]?.available == true)
    }
}
