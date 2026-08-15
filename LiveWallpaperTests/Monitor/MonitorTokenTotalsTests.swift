import Foundation
@testable import LiveWallpaper
import Testing

@Suite("MonitorTokenTotals: saturating add")
struct MonitorTokenTotalsTests {
    @Test("Near-Int.max totals add without trapping and cap at Int.max")
    func addingNearIntMaxSaturatesInsteadOfTrapping() {
        let lhs = MonitorTokenTotals(
            input: Int.max - 1, output: Int.max - 1,
            cacheRead: Int.max - 1, cacheWrite: Int.max - 1
        )
        let rhs = MonitorTokenTotals(input: 2, output: 2, cacheRead: 2, cacheWrite: 2)

        let sum = lhs + rhs

        #expect(sum.input == Int.max)
        #expect(sum.output == Int.max)
        #expect(sum.cacheRead == Int.max)
        #expect(sum.cacheWrite == Int.max)
    }

    @Test("Near-Int.min totals add without trapping and floor at Int.min")
    func addingNearIntMinSaturatesInsteadOfTrapping() {
        let lhs = MonitorTokenTotals(
            input: Int.min + 1, output: Int.min + 1,
            cacheRead: Int.min + 1, cacheWrite: Int.min + 1
        )
        let rhs = MonitorTokenTotals(input: -2, output: -2, cacheRead: -2, cacheWrite: -2)

        let sum = lhs + rhs

        #expect(sum.input == Int.min)
        #expect(sum.output == Int.min)
        #expect(sum.cacheRead == Int.min)
        #expect(sum.cacheWrite == Int.min)
    }

    @Test("Non-overflowing totals still add exactly")
    func addingWithinRangeIsExact() {
        let lhs = MonitorTokenTotals(input: 100, output: 20, cacheRead: 300, cacheWrite: 40)
        let rhs = MonitorTokenTotals(input: 10, output: 5, cacheRead: 0, cacheWrite: 0)

        let sum = lhs + rhs

        #expect(sum == MonitorTokenTotals(input: 110, output: 25, cacheRead: 300, cacheWrite: 40))
    }
}
