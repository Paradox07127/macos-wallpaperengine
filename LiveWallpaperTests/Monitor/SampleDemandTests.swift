import Testing
import Foundation
import LiveWallpaperCore
import os
@testable import LiveWallpaper

/// A board's widgets are the only subscribers of the system source. These prove
/// that a metric group with no subscribed widget is not sampled at all — the
/// probe is skipped, not just its result hidden.
@Suite("Monitor sample demand")
struct SampleDemandTests {
    private actor MockSink: MonitorSnapshotSink {
        private(set) var lastSystem: MonitorSystemSnapshot?
        private(set) var systemUpdateCount = 0

        func updateSystem(_ snapshot: MonitorSystemSnapshot) async {
            lastSystem = snapshot
            systemUpdateCount += 1
        }
        func updateAgents(sourceID: String, sessions: [MonitorAgentSessionState]) async {}
        func updateHealth(_ health: MonitorSourceHealth) async {}
        func updateNowPlaying(_ state: MonitorNowPlayingState?) async {}

        func system() -> MonitorSystemSnapshot? { lastSystem }
        func count() -> Int { systemUpdateCount }
    }

    /// Runs the source until at least one snapshot lands, then stops it.
    private func firstSnapshot(
        options: SystemMetricsSource.Options,
        loadAverageSampler: @escaping @Sendable () -> [Double]? = { [1.0, 1.0, 1.0] }
    ) async -> MonitorSystemSnapshot? {
        let sink = MockSink()
        let source = SystemMetricsSource(
            options: options,
            interval: 60,
            loadAverageSampler: loadAverageSampler
        )
        await source.start(sink: sink)
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if await sink.count() >= 1 { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        await source.stop()
        return await sink.system()
    }

    // MARK: - The probe itself must not run (injectable-seam proof)

    @Test("No CPU widget on the board: the load-average sampler is never invoked", .timeLimit(.minutes(1)))
    func noCPUWidgetSkipsLoadSampler() async {
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let snapshot = await firstSnapshot(
            options: Runtime.systemOptions(for: [.network]),
            loadAverageSampler: {
                calls.withLock { $0 += 1 }
                return [9.0, 9.0, 9.0]
            }
        )
        #expect(snapshot != nil)
        #expect(calls.withLock { $0 } == 0)
        #expect(snapshot?.loadAverage1 == nil)
        #expect(snapshot?.cpuLoadAvg == nil)
    }

    @Test("A CPU widget keeps the load-average sampler running (control)", .timeLimit(.minutes(1)))
    func cpuWidgetKeepsLoadSampler() async {
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let snapshot = await firstSnapshot(
            options: Runtime.systemOptions(for: [.cpu]),
            loadAverageSampler: {
                calls.withLock { $0 += 1 }
                return [1.25, 0.75, 0.5]
            }
        )
        #expect(calls.withLock { $0 } == 1)
        #expect(snapshot?.loadAverage1 == 1.25)
    }

    // MARK: - Undemanded groups leave no trace in the snapshot

    @Test("No CPU widget: host CPU, per-core, and CPU identity are unsampled", .timeLimit(.minutes(1)))
    func noCPUWidgetSkipsCPUSampling() async {
        let snapshot = await firstSnapshot(options: Runtime.systemOptions(for: [.network]))
        #expect(snapshot?.cpuTotal == 0)
        #expect(snapshot?.perCore == nil)
        #expect(snapshot?.cpuInfo == nil)
    }

    @Test("No memory widget: memory, swap, and pressure are unsampled", .timeLimit(.minutes(1)))
    func noMemoryWidgetSkipsMemorySampling() async {
        let snapshot = await firstSnapshot(options: Runtime.systemOptions(for: [.cpu]))
        #expect(snapshot?.memTotalBytes == 0)
        #expect(snapshot?.memUsedBytes == 0)
        #expect(snapshot?.memBreakdown == nil)
        #expect(snapshot?.swapUsedBytes == nil)
        // A demanded group still samples on the same tick (control group).
        #expect(snapshot?.cpuInfo != nil)
    }

    @Test("No network widget: interfaces stay empty and the path monitor never starts", .timeLimit(.minutes(1)))
    func noNetworkWidgetSkipsNetworkProbes() async {
        let sink = MockSink()
        let source = SystemMetricsSource(
            options: Runtime.systemOptions(for: [.memory]),
            interval: 60,
            loadAverageSampler: { nil }
        )
        await source.start(sink: sink)
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if await sink.count() >= 1 { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        #if DEBUG
        #expect(source.debugNetPathStarted == false)
        #endif
        await source.stop()
        let snapshot = await sink.system()
        #expect(snapshot?.netInterfaces == nil)
        #expect(snapshot?.netPath == nil)
        // Control: the demanded memory group did sample.
        #expect((snapshot?.memTotalBytes ?? 0) > 0)
    }

    @Test("A network widget starts the path monitor (control)", .timeLimit(.minutes(1)))
    func networkWidgetStartsPathMonitor() async {
        let sink = MockSink()
        let source = SystemMetricsSource(
            options: Runtime.systemOptions(for: [.network]),
            interval: 60,
            loadAverageSampler: { nil }
        )
        await source.start(sink: sink)
        #if DEBUG
        #expect(source.debugNetPathStarted == true)
        #endif
        await source.stop()
    }

    @Test("No power widget: battery and power-source probes are unsampled", .timeLimit(.minutes(1)))
    func noPowerWidgetSkipsPowerSampling() async {
        let snapshot = await firstSnapshot(options: Runtime.systemOptions(for: [.cpu]))
        #expect(snapshot?.powerSource == nil)
        #expect(snapshot?.batteryLevel == nil)
        #expect(snapshot?.batteryCharging == nil)
        #expect(snapshot?.lowPowerMode == nil)
    }

    // MARK: - Kind → base-group mapping

    @Test("Each widget kind demands exactly its base metric group")
    func kindDemandsItsBaseGroup() {
        let cpuOnly = Runtime.systemOptions(for: [.cpu])
        #expect(cpuOnly.cpu && !cpuOnly.memory && !cpuOnly.network && !cpuOnly.disk && !cpuOnly.power)

        let memOnly = Runtime.systemOptions(for: [.memory])
        #expect(!memOnly.cpu && memOnly.memory && !memOnly.network && !memOnly.disk && !memOnly.power)

        let netOnly = Runtime.systemOptions(for: [.network])
        #expect(!netOnly.cpu && !netOnly.memory && netOnly.network && !netOnly.disk && !netOnly.power)

        let diskOnly = Runtime.systemOptions(for: [.disk])
        #expect(!diskOnly.cpu && !diskOnly.memory && !diskOnly.network && diskOnly.disk && !diskOnly.power)

        let powerOnly = Runtime.systemOptions(for: [.power])
        #expect(!powerOnly.cpu && !powerOnly.memory && !powerOnly.network && !powerOnly.disk && powerOnly.power)
    }

    @Test("Kinds with no base-group needs leave every base gate off")
    func inertKindsLeaveBaseGatesOff() {
        let kindSets: [Set<MonitorWidgetKind>] = [[.processes], [.aiEngine], [.gpu], []]
        for kinds in kindSets {
            let opts = Runtime.systemOptions(for: kinds)
            #expect(!opts.cpu && !opts.memory && !opts.network && !opts.disk && !opts.power)
        }
    }

    @Test("Base groups union across kinds")
    func baseGroupsUnionAcrossKinds() {
        let opts = Runtime.systemOptions(for: [.cpu, .network, .power])
        #expect(opts.cpu && opts.network && opts.power)
        #expect(!opts.memory && !opts.disk)
    }

    @Test("The legacy no-widget-info path fails open: every base group stays on")
    func legacyPathFailsOpen() {
        let defaults = SystemMetricsSource.Options.default
        #expect(defaults.cpu && defaults.memory && defaults.network && defaults.disk && defaults.power)
    }
}
