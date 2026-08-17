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
