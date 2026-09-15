@testable import LiveWallpaperCore
import Testing

struct SliderValueGridTests {
    @Test func fineStepsRemainReachable() {
        let grid = SliderValueGrid(in: 0 ... 300, step: 0.001)
        #expect(abs(grid.normalized(0.1234) - 0.123) < 1e-12)
    }

    @Test func fractionalOriginAndEndpoints() {
        let grid = SliderValueGrid(in: -0.15 ... 0.85, step: 0.1)
        #expect(abs(grid.normalized(0.08) - 0.05) < 1e-12)
        #expect(grid.normalized(-99) == -0.15)
        #expect(grid.normalized(99) == 0.85)
    }

    @Test func veryLargeValueSpaceDoesNotCoarsenStep() {
        let grid = SliderValueGrid(in: 100_000 ... 100_000_000, step: 0.001)
        #expect(abs(grid.normalized(100_000.1234) - 100_000.123) < 1e-8)
    }

    @Test func nonGridEndpointKeepsExistingRoundingSemantics() {
        let grid = SliderValueGrid(in: 0 ... 1, step: 0.3)
        #expect(abs(grid.normalized(1) - 0.9) < 1e-12)
        #expect(abs(grid.normalized(grid.normalized(0.55)) - 0.6) < 1e-12)
    }
}
