#if !LITE_BUILD
import Foundation
import Testing
@testable import LiveWallpaper

@Suite("WPEFrameOccupancyMeter")
struct WPEFrameOccupancyMeterTests {

    @Test("Disabled meter accumulates nothing")
    func disabledMeterAccumulatesNothing() throws {
        try #require(!WPEFrameOccupancyMeter.isEnabled)
        WPEFrameOccupancyMeter.count(.sceneCommandBuffer)
        WPEFrameOccupancyMeter.count(.renderPassEncoder, by: 5)
        WPEFrameOccupancyMeter.count(.videoConversionCommandBuffer)
        #expect(WPEFrameOccupancyMeter.countsForTesting().allSatisfy { $0 == 0 })
    }

    @Test("Window aggregation reports totals and per-second rates")
    func windowAggregationReportsTotalsAndRates() throws {
        var state = WPEFrameOccupancyMeter.State()
        // The first sample opens the window and never reports.
        #expect(state.count(.sceneCommandBuffer, by: 1, now: 100) == nil)
        for _ in 0..<599 {
            #expect(state.count(.sceneCommandBuffer, by: 1, now: 105) == nil)
        }
        let reported = state.count(.renderPassEncoder, by: 400, now: 110)
        let report = try #require(reported)
        #expect(report == "[occupancy] 10.0s cb=600(60.0/s) passEnc=400(40.0/s)")

        // Reporting resets the window: the next report carries only new counts.
        let nextReported = state.count(.bloomEncoder, by: 2, now: 120)
        let next = try #require(nextReported)
        #expect(next == "[occupancy] 10.0s bloomEnc=2(0.2/s)")
    }

    @Test("JSC crossing kinds have distinct labels")
    func jscCrossingKindsHaveDistinctLabels() {
        let labels = [
            WPEFrameOccupancyMeter.Kind.jscCall.label,
            WPEFrameOccupancyMeter.Kind.jscSetObject.label,
            WPEFrameOccupancyMeter.Kind.jscRead.label,
            WPEFrameOccupancyMeter.Kind.audioBandWrite.label,
        ]
        #expect(Set(labels).count == labels.count)
        #expect(labels.allSatisfy { $0.hasPrefix("jsc") || $0 == "audioBand" })
    }

    @Test("Report contains only non-zero kinds")
    func reportOmitsZeroKinds() throws {
        var state = WPEFrameOccupancyMeter.State()
        #expect(state.count(.textEncoder, by: 3, now: 0) == nil)
        let reported = state.count(.textEncoder, by: 1, now: 12)
        let report = try #require(reported)
        #expect(report == "[occupancy] 12.0s textEnc=4(0.3/s)")
        for kind in WPEFrameOccupancyMeter.Kind.allCases where kind != .textEncoder {
            #expect(!report.contains(kind.label))
        }
    }
}
#endif
