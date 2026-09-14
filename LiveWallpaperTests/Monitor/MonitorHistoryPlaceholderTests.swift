import Foundation
import Testing
import LiveWallpaperCore
@testable import LiveWallpaper

@Suite("Monitor history placeholder handling")
@MainActor
struct MonitorHistoryPlaceholderTests {
    @Test("A time window excludes an earlier spike at every supported cadence")
    func timeWindowAndPeakShareTheSameRange() {
        for cadence in [0.5, 1.0, 5.0] {
            var history = MonitorHistorySnapshot()
            history.sampleTimes = (0 ..< 240).map { Double($0) * cadence }
            history.cpuTotal = [0.99] + Array(repeating: 0.2, count: 239)
            let values = history.windowed(history.cpuTotal, seconds: 30)
            #expect(values.max() == 0.2)
            #expect(values.count == Int(30 / cadence) + 1)
        }
        var sparse = MonitorHistorySnapshot()
        sparse.sampleTimes = [1, 100]
        #expect(sparse.windowed([0.9, 0.2], seconds: 30) == [0.2])
    }

    @Test("Agent updates cannot resample or integrate an old system reading")
    func brokerUpdatesDoNotDuplicateMeasurements() {
        let store = MonitorHistoryStore()
        var frame = Self.snapshot(cpuTotal: 0.2)
        frame.system?.sampledAt = 100
        frame.timestamp = 100
        store.ingest(frame)
        frame.timestamp = 105
        store.ingest(frame)
        #expect(store.current.sampleTimes == [100])
    }

    @Test("Fresh zero, unavailable, and stale measurements have distinct presentation")
    func sampleAvailabilityControlsPresentation() {
        let now = Date(timeIntervalSince1970: 100)
        var context = MonitorWidgetContext(snapshot: MonitorSnapshot(), history: MonitorHistorySnapshot(), placement: MonitorWidgetPlacement(kind: .cpu), isEditing: false, reduceMotion: true, now: now)
        #expect(context.readingsNotice != nil)
        var system = MonitorSystemSnapshot(cpuTotal: 0)
        system.metricSamples = ["cpu": MonitorMetricSample(available: true, sampledAt: 100, interval: 1)]
        context.snapshot.system = system
        #expect(context.readingsNotice == nil)
        context.now = Date(timeIntervalSince1970: 116)
        #expect(context.readingsNotice != nil)
        context.now = now
        context.snapshot.system?.metricSamples?["cpu"]?.available = false
        #expect(context.readingsNotice != nil)
    }

    @Test("Baseline, a real zero, a failed read, recovery, and a re-push stay distinct")
    func availabilityTransitionsAreDistinguishable() {
        let store = MonitorHistoryStore()
        #expect(store.current.cpuTotal.isEmpty)
        store.ingest(Self.provenanced(at: 100, cpuTotal: 0.4, cpuAvailable: true))
        store.ingest(Self.provenanced(at: 101, cpuTotal: 0, cpuAvailable: true))
        store.ingest(Self.provenanced(at: 102, cpuTotal: 0, cpuAvailable: false))
        store.ingest(Self.provenanced(at: 103, cpuTotal: 0.2, cpuAvailable: true))
        store.ingest(Self.provenanced(at: 103, cpuTotal: 0.9, cpuAvailable: true))

        #expect(store.current.sampleTimes == [100, 101, 102, 103])
        #expect(store.current.cpuTotal == [0.4, 0, nil, 0.2])
        #expect(store.current.cpuPeak == 0.4)
    }

    @Test("A measured zero rate is kept while an unsampled one is not")
    func zeroRateIsNotAbsence() {
        let store = MonitorHistoryStore()
        var frame = Self.provenanced(at: 100, cpuTotal: 0.1, cpuAvailable: true)
        frame.system?.metricSamples?["disk"] = MonitorMetricSample(
            available: true, sampledAt: 100, interval: 1
        )
        frame.system?.diskReadBytesPerSec = 0
        store.ingest(frame)

        #expect(store.current.diskRead == [0])
        // No network provenance in that frame: absent, not a zero line.
        #expect(store.current.netRx == [nil])
    }

    @Test("One absent GPU sub-reading leaves its siblings at the same time position")
    func gpuSubReadingsStayIndependent() {
        let store = MonitorHistoryStore()
        var first = Self.provenanced(at: 100, cpuTotal: 0.1, cpuAvailable: true)
        first.system?.gpuSampledAt = 100
        first.system?.gpuUsage = 0.6
        first.system?.gpuTilerUtil = 0.3
        store.ingest(first)

        var second = Self.provenanced(at: 106, cpuTotal: 0.1, cpuAvailable: true)
        second.system?.gpuSampledAt = 106
        second.system?.gpuRendererUtil = 0.45
        store.ingest(second)

        #expect(store.current.gpuSampleTimes == [100, 106])
        #expect(store.current.gpuDevice == [0.6, nil])
        #expect(store.current.gpuRenderer == [nil, 0.45])
        #expect(store.current.gpuTiler == [0.3, nil])
    }

    @Test("The four memory bands stay index-aligned when the breakdown is missing")
    func memoryBandsStayAligned() {
        let store = MonitorHistoryStore()
        var frame = Self.provenanced(at: 100, cpuTotal: 0.1, cpuAvailable: true)
        frame.system?.memTotalBytes = 16
        frame.system?.memUsedBytes = 8
        frame.system?.metricSamples?["memory"] = MonitorMetricSample(
            available: true, sampledAt: 100, interval: 1
        )
        store.ingest(frame)

        frame.system?.memBreakdown = MonitorMemoryBreakdown(
            appBytes: 4, wiredBytes: 2, compressedBytes: 1
        )
        frame.system?.sampledAt = 101
        frame.timestamp = 101
        store.ingest(frame)

        #expect(store.current.memUsedFraction == [nil, 0.5])
        #expect(store.current.memAppFraction == [nil, 0.25])
        #expect(store.current.memWiredFraction == [nil, 0.125])
        #expect(store.current.memCompressedFraction == [nil, 0.0625])
    }

    @Test("X comes from the timestamp, at every cadence and every window length")
    func timeAxisPlacesSamplesByTimestamp() {
        for cadence in [0.5, 1.0, 5.0] {
            let window = MonitorChartWindow(reference: 100, seconds: 60, interval: cadence)
            #expect(ChartTimeAxis.x(100, in: window, width: 120) == 120)
            #expect(ChartTimeAxis.x(70, in: window, width: 120) == 60)
            #expect(ChartTimeAxis.x(55, in: window, width: 120) == 30)
        }
        for seconds in [30.0, 60.0, 120.0] {
            let window = MonitorChartWindow(reference: 100, seconds: seconds, interval: 1)
            #expect(ChartTimeAxis.x(100, in: window, width: 120) == 120)
            #expect(ChartTimeAxis.x(100 - seconds / 2, in: window, width: 120) == 60)
        }
    }

    @Test("A gap wider than the sampling tolerance breaks the path; a real zero does not")
    func gapsBreakThePath() {
        let tolerance = MonitorChartWindow(reference: 200, seconds: 200, interval: 1).tolerance
        let steady = [MonitorHistoryPoint].evenlySpaced([1, 2, 3, 4], endingAt: 200)
        #expect(ChartTimeAxis.runs(steady, tolerance: tolerance) == [0 ..< 4])

        // Two minutes with the board paused: two runs, no line across the gap.
        let paused = [
            MonitorHistoryPoint(time: 60, value: 1),
            MonitorHistoryPoint(time: 61, value: 2),
            MonitorHistoryPoint(time: 181, value: 3),
            MonitorHistoryPoint(time: 182, value: 4),
        ]
        #expect(ChartTimeAxis.runs(paused, tolerance: tolerance) == [0 ..< 2, 2 ..< 4])

        let dropped = [MonitorHistoryPoint].evenlySpaced([1, nil, 0, 4], endingAt: 200)
        #expect(ChartTimeAxis.runs(dropped, tolerance: tolerance) == [0 ..< 1, 2 ..< 4])
    }

    @Test("A peak readout takes only valid samples from inside the window")
    func peakUsesValidSamplesInsideTheWindow() {
        var history = MonitorHistorySnapshot()
        history.sampleTimes = [10, 70, 100, 130]
        history.diskRead = [999, nil, 0, 42]
        let window = MonitorChartWindow(reference: 130, seconds: 60, interval: 30)
        #expect(history.values(history.diskRead, in: window) == [0, 42])
    }

    /// Provenance-carrying frame: `metricSamples` is how a snapshot says a group produced
    /// no reading.
    private static func provenanced(
        at time: Double, cpuTotal: Double, cpuAvailable: Bool
    ) -> MonitorSnapshot {
        var system = MonitorSystemSnapshot()
        system.cpuTotal = cpuTotal
        system.sampledAt = time
        system.metricSamples = [
            "cpu": MonitorMetricSample(available: cpuAvailable, sampledAt: time, interval: 1),
        ]
        var snapshot = MonitorSnapshot()
        snapshot.timestamp = time
        snapshot.system = system
        return snapshot
    }

    private static func snapshot(cpuTotal: Double) -> MonitorSnapshot {
        var snapshot = MonitorSnapshot()
        snapshot.timestamp = Date().timeIntervalSince1970
        snapshot.system = MonitorSystemSnapshot(
            cpuTotal: cpuTotal,
            cpuUser: 0,
            cpuSystem: 0,
            perCore: nil,
            memUsedBytes: 0,
            memTotalBytes: 0,
            memPressure: "normal",
            swapUsedBytes: nil,
            gpuUsage: nil,
            thermalState: "nominal"
        )
        return snapshot
    }

    @Test("Resetting clears a series built from unsampled placeholders")
    func resetClearsPlaceholderSeries() {
        let store = MonitorHistoryStore(capacity: 120)

        // Times must be strictly increasing and non-zero: `ingest` treats 0 as absent and drops
        // a sample that does not advance the clock, and without a measurement time an unchanged
        // reading is a republish, not a sample.
        for index in 1...10 {
            var placeholder = Self.snapshot(cpuTotal: 0)
            placeholder.timestamp = Double(index)
            placeholder.system?.sampledAt = Double(index)
            store.ingest(placeholder)
        }
        #expect(store.current.cpuTotal.count == 10)
        #expect(store.current.cpuTotal.allSatisfy { $0 == 0 })

        store.reset()

        #expect(store.current.cpuTotal.isEmpty)
        #expect(store.current.sampleTimes.isEmpty)
    }

    /// Control: a real zero reading is byte-identical to the placeholder, so the series
    /// cannot be filtered after the fact.
    @Test("A real idle reading is indistinguishable from the placeholder")
    func realIdleReadingLooksLikeThePlaceholder() {
        let store = MonitorHistoryStore(capacity: 120)
        var real = Self.snapshot(cpuTotal: 0)
        real.timestamp = 1
        store.ingest(real)
        #expect(store.current.cpuTotal == [0])
    }
}

@Suite("Monitor history sharing across displays")
@MainActor
struct MonitorHistorySharingTests {
    private static func snapshot(at time: Double, cpuTotal: Double) -> MonitorSnapshot {
        var snapshot = MonitorSnapshot()
        snapshot.timestamp = time
        var system = MonitorSystemSnapshot()
        system.cpuTotal = cpuTotal
        snapshot.system = system
        return snapshot
    }

    @Test("a display fed nothing still sees the history the others accumulated")
    func hiddenDisplayKeepsUpThroughTheSharedStore() {
        let shared = MonitorHistoryStore()
        let visible = DataModel(historyStore: shared)
        let hidden = DataModel(historyStore: shared)

        for step in 0..<5 {
            visible.update(Self.snapshot(at: 1_000 + Double(step), cpuTotal: 0.1 * Double(step)))
        }

        #expect(visible.historyStore.current.cpuTotal.count == 5)
        #expect(hidden.historyStore.current.cpuTotal == visible.historyStore.current.cpuTotal)
    }

    @Test("the same snapshot ingested by every host is recorded once")
    func repeatedIngestOfOneSnapshotIsIdempotent() {
        let shared = MonitorHistoryStore()
        let a = DataModel(historyStore: shared)
        let b = DataModel(historyStore: shared)
        let c = DataModel(historyStore: shared)

        let frame = Self.snapshot(at: 1_000, cpuTotal: 0.42)
        a.update(frame)
        b.update(frame)
        c.update(frame)

        #expect(shared.current.sampleTimes == [1_000])
        #expect(shared.current.cpuTotal == [0.42])
    }

    @Test("a model given no store gets one of its own")
    func unsharedModelIsIndependent() {
        let mine = DataModel()
        let theirs = DataModel()
        mine.update(Self.snapshot(at: 1_000, cpuTotal: 0.42))

        #expect(mine.historyStore.current.cpuTotal == [0.42])
        #expect(theirs.historyStore.current.cpuTotal.isEmpty)
    }

    @Test("music updates publish track changes without collecting system history")
    func musicProjectionDoesNotCollectHistory() {
        let model = DataModel()
        let track = MonitorNowPlayingState(phase: .playing, title: "Track")
        model.updateNowPlaying(track)
        #expect(model.snapshot.nowPlaying == track)
        #expect(model.snapshot.system == nil)
        #expect(model.historyStore.current.sampleTimes.isEmpty)
        model.updateNowPlaying(nil)
        #expect(model.snapshot.nowPlaying == nil)
    }
}
