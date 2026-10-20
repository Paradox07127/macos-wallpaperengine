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
        WPEFrameOccupancyMeter.count(.helperEncoder, by: 5)
        WPEFrameOccupancyMeter.count(.videoMarkerCommandBuffer)
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
        let reported = state.count(.helperEncoder, by: 400, now: 110)
        let report = try #require(reported)
        #expect(report == "[occupancy] 10.0s cb=600(60.0/s) helperEnc=400(40.0/s)")

        let nextReported = state.count(.presentEncoder, by: 2, now: 122)
        let next = try #require(nextReported)
        #expect(next == "[occupancy] 12.0s presentEnc=2(0.2/s)")
    }
}
#endif
