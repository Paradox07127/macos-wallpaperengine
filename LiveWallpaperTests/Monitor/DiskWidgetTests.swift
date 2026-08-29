import Testing
import Foundation
@testable import LiveWallpaper

struct DiskWidgetTests {

    /// The whole point of the change: the same "60s" window has to mean the
    /// same sixty seconds whether the board is sampling twice a second or once
    /// every five. Counting samples made it mean 30s at one end of the refresh
    /// slider and 300s at the other.
    @Test("windowed cuts by wall clock, not by sample count")
    func windowedIsRateIndependent() {
        func history(step: Double, count: Int) -> MonitorHistorySnapshot {
            var h = MonitorHistorySnapshot()
            h.sampleTimes = (0..<count).map { 1_000 + Double($0) * step }
            h.diskRead = (0..<count).map(Double.init)
            return h
        }
        // 0.5 s/sample: sixty seconds is 121 points.
        let fast = history(step: 0.5, count: 400)
        #expect(fast.windowed(fast.diskRead, seconds: 60).count == 121)
        // 5 s/sample: the same sixty seconds is 13.
        let slow = history(step: 5, count: 400)
        #expect(slow.windowed(slow.diskRead, seconds: 60).count == 13)
        // Both end on the newest sample.
        #expect(fast.windowed(fast.diskRead, seconds: 60).last == 399)
        #expect(slow.windowed(slow.diskRead, seconds: 60).last == 399)
    }

    @Test("windowed keeps a drawable chart and survives a short or unaligned series")
    func windowedEdges() {
        var h = MonitorHistorySnapshot()
        h.sampleTimes = (0..<10).map { 1_000 + Double($0) }
        h.diskRead = (0..<10).map(Double.init)
        // Window shorter than one sample gap still yields two points to draw.
        #expect(h.windowed(h.diskRead, seconds: 0).count == 2)
        // Whole series when the window covers all of it.
        #expect(h.windowed(h.diskRead, seconds: 600) == h.diskRead)
        // Times out of step with the series: fall back to a count, never crash.
        var broken = MonitorHistorySnapshot()
        broken.sampleTimes = [1, 2, 3]
        broken.diskRead = (0..<30).map(Double.init)
        #expect(broken.windowed(broken.diskRead, seconds: 20).count == 20)
        // No times at all.
        var empty = MonitorHistorySnapshot()
        empty.diskRead = [1, 2, 3]
        #expect(empty.windowed(empty.diskRead, seconds: 20) == [1, 2, 3])
    }

    @Test("absent/invalid historyWindow falls back to the caller's default")
    func historyWindowFallsBackWhenAbsent() {
        #expect(DiskWidgetView.historyWindowSeconds(optionSeconds: nil, fallbackSeconds: 120) == 120)
        #expect(DiskWidgetView.historyWindowSeconds(optionSeconds: 0, fallbackSeconds: 120) == 120)
        #expect(DiskWidgetView.historyWindowSeconds(optionSeconds: -30, fallbackSeconds: 120) == 120)
        #expect(DiskWidgetView.historyWindowSeconds(optionSeconds: .nan, fallbackSeconds: 120) == 120)
        #expect(DiskWidgetView.historyWindowSeconds(optionSeconds: .infinity, fallbackSeconds: 120) == 120)
    }

    @Test("a valid historyWindow override rounds to the nearest sample, floored at 2")
    func historyWindowUsesValidOverride() {
        #expect(DiskWidgetView.historyWindowSeconds(optionSeconds: 60, fallbackSeconds: 120) == 60)
        #expect(DiskWidgetView.historyWindowSeconds(optionSeconds: 59.6, fallbackSeconds: 120) == 60)
        #expect(DiskWidgetView.historyWindowSeconds(optionSeconds: 0.4, fallbackSeconds: 120) == 2)
    }

    @Test("only the literal 'compact' collapses the split legend")
    func breakdownCompactOnlyOnLiteral() {
        #expect(DiskWidgetView.breakdownIsCompact("compact"))
        #expect(DiskWidgetView.breakdownIsCompact(nil) == false)
        #expect(DiskWidgetView.breakdownIsCompact("full") == false)
        #expect(DiskWidgetView.breakdownIsCompact("Compact") == false)
    }

    @Test("split fractions divide read/write bytes proportionally")
    func splitFractionsNormal() {
        let split = DiskWidgetView.splitFractions(readBytes: 3, writeBytes: 1)
        #expect(split.read == 0.75)
        #expect(split.write == 0.25)
    }

    @Test("a zero total yields zero fractions, never a division by zero")
    func splitFractionsZeroTotal() {
        let split = DiskWidgetView.splitFractions(readBytes: 0, writeBytes: 0)
        #expect(split.read == 0)
        #expect(split.write == 0)
    }

    @Test("negative/non-finite inputs clamp to zero before dividing")
    func splitFractionsClampsInputs() {
        let split = DiskWidgetView.splitFractions(readBytes: -5, writeBytes: 10)
        #expect(split.read == 0)
        #expect(split.write == 1)

        let nanSplit = DiskWidgetView.splitFractions(readBytes: .nan, writeBytes: 4)
        #expect(nanSplit.read == 0)
        #expect(nanSplit.write == 1)
    }
}
