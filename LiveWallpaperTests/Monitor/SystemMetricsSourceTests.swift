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

    /// An undemanded group still carries a placeholder `0`; only `metricSamples`
    /// tells it from an idle disk.
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

    /// `primeDeltaBaselines` is what keeps the first published tick real; drop it
    /// and this goes red.
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

    private typealias Counters = SystemMetricsSamplers.InterfaceCounters

    private func link(_ name: String, rx: UInt64, tx: UInt64) -> Counters {
        Counters(name: name, ibytes: rx, obytes: tx)
    }

    private func netSample(_ interfaces: [Counters]) -> SystemMetricsSamplers.NetworkCountersSample {
        SystemMetricsSamplers.NetworkCountersSample(interfaces: interfaces)
    }

    @Test("An interface that leaves and comes back does not count its history as traffic")
    func interfaceAbsenceThenReturn() throws {
        let first = netSample([link("en0", rx: 1_000_000, tx: 500_000), link("en5", rx: 5_000_000, tx: 2_000_000)])
        let absent = netSample([link("en0", rx: 1_000_100, tx: 500_050)])
        let back = netSample([link("en0", rx: 1_000_300, tx: 500_150), link("en5", rx: 5_000_400, tx: 2_000_200)])

        var baseline = SystemMetricsSamplers.networkBaseline(first)
        let whileAbsent = SystemMetricsSamplers.networkRates(previous: baseline, current: absent, interval: 1)
        #expect(whileAbsent == .init(rx: 100, tx: 50, available: true))

        baseline = SystemMetricsSamplers.networkBaseline(absent)
        let afterReturn = SystemMetricsSamplers.networkRates(previous: baseline, current: back, interval: 1)
        #expect(afterReturn == .init(rx: 200, tx: 100, available: true),
                "the returning interface's lifetime bytes would read as one second of traffic")

        let rows = try SystemMetricsSamplers.networkInterfaces(
            previous: #require(baseline), current: back.interfaces, interval: 1, activeName: nil
        )
        #expect(rows.first { $0.name == "en5" }?.rxBytesPerSec == 0)
    }

    @Test("A counter reset contributes nothing instead of a negative or huge delta")
    func counterResetContributesNothing() {
        let before = netSample([link("en0", rx: 9_000_000, tx: 4_000_000), link("en1", rx: 1000, tx: 1000)])
        let after = netSample([link("en0", rx: 40, tx: 20), link("en1", rx: 1300, tx: 1100)])
        let rates = SystemMetricsSamplers.networkRates(
            previous: SystemMetricsSamplers.networkBaseline(before), current: after, interval: 1
        )
        #expect(rates == .init(rx: 300, tx: 100, available: true))
    }

    @Test("A failed interface read drops the baseline so the next read primes instead of reporting history")
    func failedReadReprimes() {
        let first = netSample([link("en0", rx: 7_000_000, tx: 3_000_000)])
        let failed = SystemMetricsSamplers.networkRates(
            previous: SystemMetricsSamplers.networkBaseline(first), current: nil, interval: 1
        )
        #expect(failed.available == false)

        let afterFailure = SystemMetricsSamplers.networkBaseline(nil)
        #expect(afterFailure == nil)
        let recovered = SystemMetricsSamplers.networkRates(
            previous: afterFailure,
            current: netSample([link("en0", rx: 7_000_100, tx: 3_000_100)]),
            interval: 0.5
        )
        #expect(recovered == .init(rx: 0, tx: 0, available: false))
    }

    @Test("An address-only row is not a byte baseline when the link counters come back")
    func addressOnlyRowIsNotABaseline() throws {
        var down = Counters(name: "en1", addresses: ["10.0.0.2"])
        down.hasLinkCounters = false
        var up = link("en1", rx: 9_000_000, tx: 4_000_000)
        up.addresses = ["10.0.0.2"]

        let baseline = SystemMetricsSamplers.networkBaseline(netSample([down]))
        let rates = SystemMetricsSamplers.networkRates(previous: baseline, current: netSample([up]), interval: 1)
        #expect(rates == .init(rx: 0, tx: 0, available: true))

        let rows = try SystemMetricsSamplers.networkInterfaces(
            previous: #require(baseline), current: [up], interval: 1, activeName: nil
        )
        #expect(rows.first?.rxBytesPerSec == 0)
        #expect(rows.first?.txBytesPerSec == 0)
    }
}

@Suite("CPU tick counters")
struct CPUTickCounterTests {
    private typealias Core = (user: UInt32, system: UInt32, idle: UInt32, nice: UInt32)

    private func sample(
        _ cores: [Core],
        previous: SystemMetricsSamplers.CPURawCounters?
    ) -> (sample: SystemMetricsSamplers.CPUSample, counters: SystemMetricsSamplers.CPURawCounters) {
        let stride = Int(CPU_STATE_MAX)
        var info = [integer_t](repeating: 0, count: cores.count * stride)
        for (index, core) in cores.enumerated() {
            info[index * stride + Int(CPU_STATE_USER)] = integer_t(bitPattern: core.user)
            info[index * stride + Int(CPU_STATE_SYSTEM)] = integer_t(bitPattern: core.system)
            info[index * stride + Int(CPU_STATE_IDLE)] = integer_t(bitPattern: core.idle)
            info[index * stride + Int(CPU_STATE_NICE)] = integer_t(bitPattern: core.nice)
        }
        return info.withUnsafeBufferPointer {
            SystemMetricsSamplers.cpuSample(loadInfo: $0, cpuCount: cores.count, previous: previous)
        }
    }

    private func close(_ lhs: Double, _ rhs: Double) -> Bool {
        abs(lhs - rhs) < 1e-9
    }

    @Test("Counters past Int32.max read as unsigned ticks")
    func countersWithTheHighBitSet() {
        let first = sample([(0x7FFF_FFFF, 100, 1000, 0)], previous: nil)
        let second = sample([(0x8000_0063, 100, 1100, 0)], previous: first.counters)
        #expect(second.sample.available)
        #expect(close(second.sample.total, 0.5))
        #expect(close(second.sample.user, 0.5))
        #expect(close(second.sample.system, 0))
        #expect(second.sample.perCore.count == 1)
        #expect(second.sample.perCore.first.map { close($0, 0.5) } == true)
    }

    @Test("A counter that wraps past UInt32.max contributes its 32-bit delta")
    func countersWrapAt32Bits() {
        let first = sample([(0xFFFF_FFFE, 0, 0, 0), (10, 0, 0xFFFF_FFCE, 0)], previous: nil)
        let second = sample([(0x30, 0, 150, 0), (110, 0, 0x32, 0)], previous: first.counters)
        #expect(second.sample.available)
        #expect(close(second.sample.total, 0.375))
        #expect(second.sample.perCore.count == 2)
        #expect(second.sample.perCore.first.map { close($0, 0.25) } == true)
        #expect(second.sample.perCore.last.map { close($0, 0.5) } == true)
    }

    @Test("A changed core count starts a new baseline instead of mixing topologies")
    func topologyChangeReprimes() {
        let first = sample([(100, 100, 100, 0)], previous: nil)
        let second = sample([(150, 100, 150, 0), (10, 10, 10, 0)], previous: first.counters)
        #expect(second.sample.available == false)
        let third = sample([(250, 100, 250, 0), (20, 10, 20, 0)], previous: second.counters)
        #expect(third.sample.available)
        #expect(close(third.sample.total, 0.5))
    }
}
