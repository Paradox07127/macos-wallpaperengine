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

    @Test func unrepresentableGridIndexPreservesFiniteInput() {
        let grid = SliderValueGrid(in: 0 ... 1, step: .leastNonzeroMagnitude)
        #expect(grid.normalized(0.5) == 0.5)
        #expect(grid.normalized(1) == 1)
        let wide = SliderValueGrid(in: -1e308 ... 1e308, step: 1)
        #expect(wide.normalized(1e308) == 1e308)
        let coarse = SliderValueGrid(in: 0 ... 1e308, step: 1e308)
        #expect(coarse.normalized(9e307) == 1e308)
        #expect(SliderValueGrid(in: -2 ... 3, step: 0.25).normalized(0.37) == 0.25)
        #expect(SliderValueGrid(in: 0 ... 1, step: 2).normalized(0.4) == 0)
        #expect(SliderValueGrid(in: 0 ... 1, step: 2).normalized(1) == 1)
    }

    @Test func nonfiniteValuesAndStepsKeepFiniteFallbacks() {
        for step in [Double.nan, .infinity, -.infinity, 0, -1] {
            #expect(SliderValueGrid(in: 0 ... 1, step: step).normalized(0.5) == 0.5)
        }
        let grid = SliderValueGrid(in: -1 ... 1, step: 0.5)
        #expect(grid.normalized(.nan) == -1)
        #expect(grid.normalized(.infinity) == 1)
        #expect(grid.normalized(-.infinity) == -1)
        #expect(SliderValueGrid(in: .infinity ... .infinity, step: 1).normalized(0) == 0)
    }
}
