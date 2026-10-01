#if !LITE_BUILD
import Foundation
@testable import LiveWallpaper
import LiveWallpaperProWPE
import Metal
import Testing

@Suite("Captured particle instance birth properties and simulation rate")
struct WPEParticleInstanceModifierTests {
    @Test func changingBirthPropertiesKeepsOldParticlesAndUploadsNewValues() throws {
        let system = try makeSystem()
        system.applyPlaybackCommand(.pause)
        system.applyPlaybackCommand(.emit(1))
        system.tick(now: 0)
        system.tick(now: 0.05)
        let oldIdentity = try #require(system.primaryLiveParticleIdentity)
        let old = try #require(system.snapshot(for: oldIdentity))
        for (property, value) in [(WPEParticleInstanceProperty.alpha, 0.5), (.size, 2), (.speed, 2), (.lifetime, 0.5)] {
            system.applyPlaybackCommand(.modify(.init(property: property, value: SIMD3(repeating: value))))
        }
        system.applyPlaybackCommand(.modify(.init(property: .colorn, value: SIMD3(0, 1, 0))))
        system.applyPlaybackCommand(.emit(1))
        system.tick(now: 0.1)
        let unchanged = try #require(system.snapshot(for: oldIdentity))
        #expect(unchanged.initialAlpha == old.initialAlpha && unchanged.initialSize == old.initialSize)
        #expect(unchanged.initialColor == old.initialColor && unchanged.lifetime == old.lifetime)
        #expect(unchanged.velocity == old.velocity)
        let newIdentity = try #require(system.primaryLiveParticleIdentity)
        #expect(newIdentity != oldIdentity)
        let new = try #require(system.snapshot(for: newIdentity))
        #expect(new.initialAlpha == 0.5 && new.initialSize == 16)
        #expect(new.initialColor == SIMD3(0, 1, 0) && new.lifetime == 5)
        #expect(new.velocity.x == 32 && unchanged.velocity.x == 16)
        let uploaded = system.instanceBuffer.contents().bindMemory(to: WPEParticleInstance.self, capacity: system.capacity)
        #expect(uploaded[0].color == SIMD4(1, 0, 0, 1))
        #expect(uploaded[1].color == SIMD4(0, 1, 0, 0.5))
    }

    @Test func authoredOverrideColornMultipliesTheSampledColorAndKeepsItsVariance() throws {
        let definition = WPEParticleDefinitionParser.parse(dictionary: [
            "maxcount": 8,
            "emitter": [["name": "boxrandom", "rate": 0, "instantaneous": 8]],
            "initializer": [["name": "lifetimerandom", "min": 10, "max": 10],
                            ["name": "colorrandom", "min": "100 100 100", "max": "200 200 200"]],
        ])
        let device = try #require(MTLCreateSystemDefaultDevice())
        let system = try #require(WPEParticleSystem(definition: definition, device: device, seed: 61))
        system.instanceValues = WPEParticleInstanceValues(override: WPESceneParticleInstanceOverride(color: SIMD3(255, 0, 0)))
        system.tick(now: 0)
        #expect(system.liveInstanceCount == 8)
        let uploaded = system.instanceBuffer.contents().bindMemory(to: WPEParticleInstance.self, capacity: system.capacity)
        let colors = (0 ..< 8).map { uploaded[$0].color }
        #expect(colors.allSatisfy { $0.x >= 100 / 255 - 1e-4 && $0.x <= 200 / 255 + 1e-4 })
        #expect(colors.allSatisfy { $0.y == 0 && $0.z == 0 })
        #expect(Set(colors.map(\.x)).count > 1)
    }

    @Test func explicitEmissionCapturesCallTimePropertiesBeforeLaterMutations() throws {
        let system = try makeSystem()
        system.applyPlaybackCommand(.stop)
        var earlier = WPEParticleInstanceValues()
        earlier.alpha = 0.25
        system.requestEmission(1, values: earlier)
        system.instanceAlphaScale = 0.5
        system.applyPlaybackCommand(.emit(3))
        system.instanceAlphaScale = 0.75
        system.tick(now: 0)
        #expect(system.liveInstanceCount == 4)
        let uploaded = system.instanceBuffer.contents().bindMemory(to: WPEParticleInstance.self, capacity: system.capacity)
        #expect(uploaded[0].color.w == 0.25)
        #expect((1 ... 3).allSatisfy { uploaded[$0].color.w == 0.5 })
        #expect(system.instanceAlphaScale == 0.75)
    }

    @Test func scriptedAlphaIsStoredOnBirthAsInWindowsExplicitEmitProbe() throws {
        let system = try makeSystem()
        system.applyPlaybackCommand(.stop)
        system.instanceAlphaScale = 0.25
        system.applyPlaybackCommand(.emit(1))
        system.tick(now: 0)
        let first = try #require(system.primaryLiveParticleIdentity)
        system.instanceAlphaScale = 0.5
        system.applyPlaybackCommand(.emit(3))
        system.tick(now: 0.05)
        #expect(system.liveInstanceCount == 4)
        #expect(system.snapshot(for: first)?.currentAlpha == 0.25)
        let uploaded = system.instanceBuffer.contents().bindMemory(to: WPEParticleInstance.self, capacity: system.capacity)
        #expect(uploaded[0].color.w == 0.25)
        #expect((1 ... 3).allSatisfy { uploaded[$0].color.w == 0.5 })
    }

    @Test func animatedOverrideAlphaIsNotAlsoAppliedAsTheBirthSeed() throws {
        let definition = WPEParticleDefinitionParser.parse(dictionary: [
            "maxcount": 1,
            "emitter": [["name": "boxrandom", "rate": 0, "instantaneous": 1]],
            "initializer": [["name": "lifetimerandom", "min": 10, "max": 10]],
        ])
        let ramp = WPESceneAnimatedValue(
            animation: WPESceneNumericAnimation(
                tracks: [[.init(frame: 0, value: 0), .init(frame: 15, value: 1), .init(frame: 30, value: 1)]],
                fps: 30, length: 30, mode: "loop", wrapLoop: true
            ),
            scalarFallback: 0,
            vectorFallback: nil
        )
        let override = WPESceneParticleInstanceOverride(alpha: 0, alphaAnimation: ramp)
        let device = try #require(MTLCreateSystemDefaultDevice())
        let system = try #require(WPEParticleSystem(
            definition: definition.applying(instanceOverride: override), device: device, seed: 62
        ))
        system.instanceValues = WPEParticleInstanceValues(override: override)
        system.tick(now: 0)
        system.tick(now: 0.75)
        #expect(system.liveInstanceCount == 1)
        let uploaded = system.instanceBuffer.contents().bindMemory(to: WPEParticleInstance.self, capacity: system.capacity)
        #expect(uploaded[0].color.w == 1)
    }

    @Test func rateChangesMotionAgeAndEmissionTogetherAndZeroUsesCapturedMinimum() throws {
        let system = try makeSystem()
        system.applyPlaybackCommand(.pause)
        system.applyPlaybackCommand(.emit(1))
        system.tick(now: 0)
        let identity = try #require(system.primaryLiveParticleIdentity)
        for (time, rate, age) in [(0.1, 0.5, 0.05), (0.2, 2.0, 0.25), (0.3, 0.0, 0.251)] {
            system.applyPlaybackCommand(.modify(.init(property: .rate, value: SIMD3(repeating: rate))))
            system.tick(now: time)
            let snapshot = try #require(system.snapshot(for: identity))
            #expect(abs(Double(snapshot.age) - age) < 0.0001)
            #expect(abs(Double(snapshot.position.x) - age * 16) < 0.0001)
        }
        let emitting = try makeSystem()
        emitting.instanceValues.rate = 0.5
        emitting.instanceValues.count = 2
        for frame in 0 ... 90 {
            emitting.tick(now: Double(frame) / 60)
        }
        #expect(emitting.liveInstanceCount == 1)
        #expect(emitting.capacity == 8)
    }

    @Test func followedInstancesResolveTheGlobalPointerInTheirOwnSimulationFrame() throws {
        let system = try makeSystem()
        system.instanceOriginOffset = SIMD3(20, 30, 0)
        system.hostOriginOffset = SIMD2(5, 7)
        #expect(system.pointerInSimulationFrame(SIMD2(100, 80)) == SIMD2(75, 43))
        #expect(system.pointerInSimulationFrame(nil) == nil)
    }

    @Test func controlPointMutationReachesTheExistingSpatialConsumer() throws {
        let system = try makeSystem()
        system.applyPlaybackCommand(.modify(.init(property: .controlpoint3, value: SIMD3(4, 5, 6))))
        #expect(system.controlPointPosition(3) == SIMD3<Float>(4, 5, 6))
    }

    private func makeSystem() throws -> WPEParticleSystem {
        let definition = WPEParticleDefinitionParser.parse(dictionary: [
            "maxcount": 8,
            "emitter": [["name": "boxrandom", "rate": 1, "instantaneous": 0]],
            "initializer": [["name": "lifetimerandom", "min": 10, "max": 10],
                            ["name": "sizerandom", "min": 8, "max": 8],
                            ["name": "velocityrandom", "min": "16 0 0", "max": "16 0 0"],
                            ["name": "colorrandom", "min": "255 0 0", "max": "255 0 0"]],
            "operator": [["name": "alphafade", "fadeintime": 0, "fadeouttime": 1]],
        ])
        let device = try #require(MTLCreateSystemDefaultDevice())
        return try #require(WPEParticleSystem(definition: definition, device: device,
                                              sceneTransform: WPEParticleSceneTransform(
                                                  sceneSize: SIMD2(16, 16), objectOrigin: SIMD3(8, 8, 0),
                                                  objectScale: SIMD3(repeating: 1), objectAngleZ: 0
                                              ), seed: 54))
    }
}
#endif
