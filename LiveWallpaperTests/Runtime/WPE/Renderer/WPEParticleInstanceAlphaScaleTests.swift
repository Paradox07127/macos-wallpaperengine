import Foundation
@testable import LiveWallpaper
import LiveWallpaperProWPE
import Metal
import simd
import Testing

@Suite("Particle instance alpha scale")
struct WPEParticleInstanceAlphaScaleTests {
    @Test("Alpha random uses initializer defaults without changing opaque particles")
    func alphaRandomDefaultsAreLocalToInitializer() throws {
        let absent = try #require(WPEParticleDefinitionParser.parse(dictionary: [:]))
        #expect(abs(absent.alphaMin - 1) < 0.000001)
        #expect(abs(absent.alphaMax - 1) < 0.000001)
        let random = try #require(WPEParticleDefinitionParser.parse(dictionary: [
            "initializer": [["name": "alpharandom", "max": 1]],
        ]))
        #expect(abs(random.alphaMin - 0.05) < 0.000001)
        #expect(abs(random.alphaMax - 1) < 0.000001)
        let explicit = try #require(WPEParticleDefinitionParser.parse(dictionary: [
            "initializer": [["name": "alpharandom", "min": 0, "max": 0.25]],
        ]))
        #expect(explicit.alphaMin == 0)
        #expect(explicit.alphaMax == 0.25)
    }

    private func makeSystem(device: MTLDevice) throws -> WPEParticleSystem {
        let definition = try #require(WPEParticleDefinitionParser.parse(dictionary: [
            "maxcount": 8,
            "material": "materials/m.json",
            "emitter": [["name": "boxrandom", "instantaneous": 8, "rate": 0]],
            "initializer": [
                ["name": "alpharandom", "min": 1, "max": 1],
                ["name": "lifetimerandom", "min": 100, "max": 100],
                ["name": "sizerandom", "min": 8, "max": 8],
            ],
        ]))
        return try #require(WPEParticleSystem(
            definition: definition, device: device,
            sceneTransform: WPEParticleSceneTransform(
                sceneSize: SIMD2<Float>(256, 256), objectOrigin: SIMD3<Float>(128, 128, 0),
                objectScale: SIMD3<Float>(1, 1, 1), objectAngleZ: 0
            ), seed: 77
        ))
    }

    private func drawnAlphas(_ system: WPEParticleSystem) -> [Float] {
        let count = system.liveInstanceCount
        guard count > 0 else { return [] }
        let pointer = system.instanceBuffer.contents()
            .bindMemory(to: WPEParticleInstance.self, capacity: count)
        return (0 ..< count).map { pointer[$0].color.w }
    }

    @Test("A scripted zero collapses every drawn alpha, and 1 leaves them untouched",
          arguments: [Float(0), 0.25, 1])
    func instanceAlphaScaleMultipliesDrawnAlpha(scale: Float) throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let baseline = try makeSystem(device: device)
        baseline.tick(now: 0)
        baseline.tick(now: 0.1)
        let unscaled = drawnAlphas(baseline)
        try #require(unscaled.count == 8)
        // Exact spawn alpha depends on the fade envelope; only the ratio matters here.
        try #require(unscaled.allSatisfy { $0 > 0 })

        let system = try makeSystem(device: device)
        system.instanceAlphaScale = scale
        system.tick(now: 0)
        system.tick(now: 0.1)
        let scaled = drawnAlphas(system)
        #expect(scaled.count == unscaled.count)
        for (index, alpha) in scaled.enumerated() {
            #expect(abs(alpha - unscaled[index] * scale) < 0.0001,
                    "instance \(index): \(alpha) != \(unscaled[index]) * \(scale)")
        }
    }

    @Test("A particle object with no alpha script is left unmarked and unscaled")
    func absentScriptLeavesSystemUnmarked() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let system = try makeSystem(device: device)
        #expect(system.instanceAlphaScriptObjectID == nil)
        #expect(system.instanceAlphaScale == 1)
    }
}
