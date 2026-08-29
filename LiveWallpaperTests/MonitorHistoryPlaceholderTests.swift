import Foundation
import Testing
@testable import LiveWallpaper

/// A metric group no placed widget reads is not sampled at all — the source
/// fills its slot with a literal `0` (`"normal"` for pressure). Those
/// placeholders are indistinguishable from a real idle reading once they are in
/// the series, so a widget added to a running board drew a fabricated flat
/// history. Nothing asserted the reset that fixes it, and
/// `SampleDemandTests.noCPUWidgetSkipsCPUSampling` characterizes the sentinel
/// itself, so deleting the reset left every test green.
@Suite("Monitor history placeholder handling")
@MainActor
struct MonitorHistoryPlaceholderTests {
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

        // Board showing only network: CPU arrives as a placeholder zero every tick.
        // Strictly increasing and non-zero: `ingest` treats 0 as "absent" and
        // drops any sample that does not advance the clock.
        for index in 1...10 {
            var placeholder = Self.snapshot(cpuTotal: 0)
            placeholder.timestamp = Double(index)
            store.ingest(placeholder)
        }
        #expect(store.current.cpuTotal.count == 10)
        #expect(store.current.cpuTotal.allSatisfy { $0 == 0 })

        store.reset()

        // A CPU widget added now must start from nothing, not from ten fake zeros.
        #expect(store.current.cpuTotal.isEmpty)
        #expect(store.current.sampleTimes.isEmpty)
    }

    /// Control: a real zero reading is byte-identical to the placeholder, which is
    /// exactly why the series cannot be filtered after the fact and the reset has
    /// to happen when the sampled set grows.
    @Test("A real idle reading is indistinguishable from the placeholder")
    func realIdleReadingLooksLikeThePlaceholder() {
        let store = MonitorHistoryStore(capacity: 120)
        var real = Self.snapshot(cpuTotal: 0)
        real.timestamp = 1
        store.ingest(real)
        #expect(store.current.cpuTotal == [0])
    }
}

/// Every board host is pushed the same snapshot from the same broker, so a
/// history store per display kept N copies of one series — and they drifted,
/// because a display that is hidden stops being pushed while the visible one
/// keeps accumulating. Two screens showing the same CPU widget then drew two
/// different charts.
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

    /// What makes sharing safe without touching the push path: N hosts each
    /// ingesting the same snapshot must record one sample, not N.
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

    /// The preview builds its own board with no store handed in, and must not
    /// end up writing into the desktop's series.
    @Test("a model given no store gets one of its own")
    func unsharedModelIsIndependent() {
        let mine = DataModel()
        let theirs = DataModel()
        mine.update(Self.snapshot(at: 1_000, cpuTotal: 0.42))

        #expect(mine.historyStore.current.cpuTotal == [0.42])
        #expect(theirs.historyStore.current.cpuTotal.isEmpty)
    }
}

