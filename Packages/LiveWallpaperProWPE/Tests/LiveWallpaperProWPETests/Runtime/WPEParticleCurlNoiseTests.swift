import Foundation
import LiveWallpaperProWPE
import Testing

struct WPEParticleCurlNoiseTests {
    @Test(arguments: [Double.infinity, -Double.infinity, Double.nan, 1e300, -1e300, 9.3e18])
    func perlinStaysFiniteOutsideTheIntegerLattice(value: Double) {
        #expect(WPEParticleCurlNoise.perlin(value, 0.5, 0.5).isFinite)
        #expect(WPEParticleCurlNoise.perlin(0.5, value, 0.5).isFinite)
        #expect(WPEParticleCurlNoise.perlin(0.5, 0.5, value).isFinite)
    }

    @Test func curlDirectionFallsBackForUnrepresentableSamplePoints() {
        let fallback = SIMD3<Double>(0, 1, 0)
        #expect(WPEParticleCurlNoise.direction(at: SIMD3(1e300, 0, 0), fallback: fallback) == fallback)
    }
}
