@testable import LiveWallpaper
import LiveWallpaperProWPE
import Metal
import Testing

struct WPEParticleSpawnFailureTests {
    private func makeSystem(rate: Double, emitterControlPointID: Int) throws -> WPEParticleSystem {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let definition = WPEParticleDefinition(
            materialRelativePath: nil,
            maxCount: 16,
            rate: rate,
            startDelay: 0,
            lifetimeMin: 100, lifetimeMax: 100,
            sizeMin: 4, sizeMax: 4,
            originOffset: .zero,
            emitterControlPointID: emitterControlPointID,
            dispersalMin: .zero, dispersalMax: .zero,
            velocityMin: .zero, velocityMax: .zero,
            colorMin: SIMD3(255, 255, 255), colorMax: SIMD3(255, 255, 255),
            fadeInSeconds: 0
        )
        return try #require(WPEParticleSystem(definition: definition, device: device))
    }

    @Test("Failed rate spawns stop the emission loop instead of retrying per accumulated birth")
    func failedSpawnStopsRateLoop() throws {
        let system = try makeSystem(rate: 1e6, emitterControlPointID: 8)
        system.tick(now: 0)
        let start = ContinuousClock.now
        system.tick(now: 1)
        let elapsed = ContinuousClock.now - start
        #expect(system.liveInstanceCount == 0)
        #expect(elapsed < .milliseconds(50), "failed spawns kept retrying within one tick (\(elapsed))")
    }

    @Test("Extreme rate with an unreachable emitter control point returns within one tick", .timeLimit(.minutes(1)))
    func extremeRateWithFailingSpawnTerminates() throws {
        let system = try makeSystem(rate: 1e20, emitterControlPointID: 8)
        system.tick(now: 0)
        system.tick(now: 0.016)
        #expect(system.liveInstanceCount == 0)
    }

    @Test("Normal rate emits floor(dt * rate) particles")
    func normalRateEmitsAccumulatedBirths() throws {
        let system = try makeSystem(rate: 10, emitterControlPointID: 0)
        // 1/16 s ticks keep every 1/64 s step and its 10/64 accumulator increment exact in binary.
        for tick in 0 ... 8 {
            system.tick(now: Double(tick) / 16)
        }
        #expect(system.liveInstanceCount == 5)
    }
}
