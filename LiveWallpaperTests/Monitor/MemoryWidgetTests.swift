import XCTest
@testable import LiveWallpaper
import LiveWallpaperCore

final class MemoryWidgetTests: XCTestCase {

    private let g = 1_073_741_824.0

    func testPressureMapping() {
        XCTAssertEqual(MemoryWidgetView.pressure("normal"), .normal)
        XCTAssertEqual(MemoryWidgetView.pressure(nil), .normal)
        XCTAssertEqual(MemoryWidgetView.pressure("warn"), .warn)
        XCTAssertEqual(MemoryWidgetView.pressure("warning"), .warn)
        XCTAssertEqual(MemoryWidgetView.pressure("critical"), .critical)
        XCTAssertEqual(MemoryWidgetView.pressure("crit"), .critical)
        XCTAssertEqual(MemoryWidgetView.pressure("bogus"), .normal)
    }

    func testSwapHiddenWhenZeroAndNormal() {
        XCTAssertFalse(MemoryWidgetView.showsSwap(swapBytes: 0, pressure: "normal"))
        XCTAssertFalse(MemoryWidgetView.showsSwap(swapBytes: nil, pressure: "normal"))
    }

    func testSwapShownWhenNonZero() {
        XCTAssertTrue(MemoryWidgetView.showsSwap(swapBytes: 1, pressure: "normal"))
        XCTAssertTrue(MemoryWidgetView.showsSwap(swapBytes: UInt64(2.4 * g), pressure: "normal"))
    }

    func testSwapShownWhenPressureRaisedEvenWithZeroSwap() {
        XCTAssertTrue(MemoryWidgetView.showsSwap(swapBytes: 0, pressure: "warn"))
        XCTAssertTrue(MemoryWidgetView.showsSwap(swapBytes: nil, pressure: "critical"))
    }

    func testSegmentsOrderLabelsAndFractions() {
        let breakdown = MonitorMemoryBreakdown(
            appBytes: UInt64(8.9 * g),
            wiredBytes: UInt64(4.2 * g),
            compressedBytes: UInt64(2.0 * g),
            cachedFilesBytes: UInt64(6.4 * g)
        )
        let total = 32 * g
        let segs = MemoryWidgetView.segments(
            breakdown: breakdown, swap: UInt64(1.1 * g), total: total)

        XCTAssertEqual(segs.map(\.kind),
                       [.app, .wired, .compressed, .cached, .swap])
        XCTAssertEqual(segs.map(\.label),
                       ["App", "Wired", "Compressed", "Cached Files", "Swap"])

        XCTAssertEqual(segs[0].fraction, 8.9 / 32, accuracy: 0.001)
        XCTAssertEqual(segs[1].fraction, 4.2 / 32, accuracy: 0.001)
        XCTAssertEqual(segs[2].fraction, 2.0 / 32, accuracy: 0.001)
        XCTAssertEqual(segs[3].fraction, 6.4 / 32, accuracy: 0.001)
        XCTAssertEqual(segs[4].fraction, 1.1 / 32, accuracy: 0.001)
    }

    func testFreeFractionIgnoresSwap() {
        let breakdown = MonitorMemoryBreakdown(
            appBytes: UInt64(8.9 * g),
            wiredBytes: UInt64(4.2 * g),
            compressedBytes: UInt64(2.0 * g),
            cachedFilesBytes: UInt64(6.4 * g)
        )
        let free = MemoryWidgetView.freeFraction(breakdown: breakdown, total: 32 * g)
        XCTAssertEqual(free, (32 - 21.5) / 32, accuracy: 0.001)
    }

    func testFractionsClampAndTotalGuard() {
        let breakdown = MonitorMemoryBreakdown(
            appBytes: UInt64(40 * g), wiredBytes: 0, compressedBytes: 0, cachedFilesBytes: 0)
        let segs = MemoryWidgetView.segments(breakdown: breakdown, swap: 0, total: 32 * g)
        XCTAssertEqual(segs[0].fraction, 1.0, accuracy: 0.0001)
        XCTAssertEqual(MemoryWidgetView.freeFraction(breakdown: breakdown, total: 32 * g), 0)
        let safe = MemoryWidgetView.segments(breakdown: breakdown, swap: 0, total: 0)
        XCTAssertTrue(safe.allSatisfy { $0.fraction.isFinite })
    }

    func testHistoryWindowSamplesFallsBackWhenOptionAbsent() {
        XCTAssertEqual(MemoryWidgetView.historyWindowSamples(optionSeconds: nil, fallbackSeconds: 60), 60)
        XCTAssertEqual(MemoryWidgetView.historyWindowSamples(optionSeconds: nil, fallbackSeconds: 120), 120)
    }

    func testHistoryWindowSamplesHonoursOverride() {
        XCTAssertEqual(MemoryWidgetView.historyWindowSamples(optionSeconds: 30, fallbackSeconds: 60), 30)
        XCTAssertEqual(MemoryWidgetView.historyWindowSamples(optionSeconds: 90.6, fallbackSeconds: 120), 91)
    }

    func testHistoryWindowSamplesRejectsInvalidOverrides() {
        XCTAssertEqual(MemoryWidgetView.historyWindowSamples(optionSeconds: 0, fallbackSeconds: 60), 60)
        XCTAssertEqual(MemoryWidgetView.historyWindowSamples(optionSeconds: -5, fallbackSeconds: 60), 60)
        XCTAssertEqual(MemoryWidgetView.historyWindowSamples(optionSeconds: .nan, fallbackSeconds: 60), 60)
        XCTAssertEqual(MemoryWidgetView.historyWindowSamples(optionSeconds: .infinity, fallbackSeconds: 60), 60)
    }

    func testHistoryWindowSamplesFloorsAtTwo() {
        XCTAssertEqual(MemoryWidgetView.historyWindowSamples(optionSeconds: 0.4, fallbackSeconds: 60), 2)
    }

    func testShowsTopProcessesDefaultsToTrue() {
        XCTAssertTrue(MemoryWidgetView.showsTopProcesses(nil))
    }

    func testShowsTopProcessesHonoursExplicitValue() {
        XCTAssertTrue(MemoryWidgetView.showsTopProcesses(true))
        XCTAssertFalse(MemoryWidgetView.showsTopProcesses(false))
    }

    func testBreakdownIsCompactOnlyForTheCompactLiteral() {
        XCTAssertFalse(MemoryWidgetView.breakdownIsCompact(nil))
        XCTAssertFalse(MemoryWidgetView.breakdownIsCompact("full"))
        XCTAssertFalse(MemoryWidgetView.breakdownIsCompact("bogus"))
        XCTAssertTrue(MemoryWidgetView.breakdownIsCompact("compact"))
    }

    func testTopByMemoryRanksDescendingByRSS() {
        let procs = [
            MonitorProcessSample(name: "Safari", cpuPercent: 3, memBytes: UInt64(0.82 * g)),
            MonitorProcessSample(name: "Xcode", cpuPercent: 22, memBytes: UInt64(3.4 * g)),
            MonitorProcessSample(name: "Helper", cpuPercent: 4, memBytes: UInt64(1.4 * g)),
        ]
        let ranked = MemoryWidgetView.topByMemory(procs, limit: 5)
        XCTAssertEqual(ranked.map(\.name), ["Xcode", "Helper", "Safari"])
    }

    func testTopByMemoryCapsAtLimit() {
        let procs = (0..<10).map {
            MonitorProcessSample(name: "p\($0)", cpuPercent: 0, memBytes: UInt64($0) * 1_000_000)
        }
        let ranked = MemoryWidgetView.topByMemory(procs, limit: 5)
        XCTAssertEqual(ranked.count, 5)
        XCTAssertEqual(ranked.map(\.name), ["p9", "p8", "p7", "p6", "p5"])
    }

    func testTopByMemoryTiesBreakByOriginalOrder() {
        let procs = [
            MonitorProcessSample(name: "first", cpuPercent: 0, memBytes: 100),
            MonitorProcessSample(name: "second", cpuPercent: 0, memBytes: 100),
        ]
        let ranked = MemoryWidgetView.topByMemory(procs, limit: 5)
        XCTAssertEqual(ranked.map(\.name), ["first", "second"])
    }

    func testTopByMemoryEmptyOrNilInputYieldsEmptyOutput() {
        XCTAssertTrue(MemoryWidgetView.topByMemory(nil, limit: 5).isEmpty)
        XCTAssertTrue(MemoryWidgetView.topByMemory([], limit: 5).isEmpty)
    }

    func testProcessBarFractionScalesToTop() {
        XCTAssertEqual(MemoryWidgetView.processBarFraction(UInt64(1.7 * g), top: UInt64(3.4 * g)), 0.5, accuracy: 0.001)
        XCTAssertEqual(MemoryWidgetView.processBarFraction(UInt64(3.4 * g), top: UInt64(3.4 * g)), 1.0, accuracy: 0.001)
    }

    func testProcessBarFractionGuardsZeroTop() {
        XCTAssertEqual(MemoryWidgetView.processBarFraction(100, top: 0), 0)
    }
}
