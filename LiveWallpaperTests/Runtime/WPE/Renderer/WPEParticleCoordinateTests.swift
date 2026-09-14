import Foundation
import LiveWallpaperProWPE
import Metal
import simd
import Testing
@testable import LiveWallpaper

struct WPEParticleCoordinateTests {

    @Test("Refractive rain uses the same object size scale as ordinary particles")
    func refractionDoesNotBypassObjectScale() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let definition = try #require(WPEParticleDefinitionParser.parse(dictionary: [
            "maxcount": 4, "emitter": [["name": "boxrandom", "instantaneous": 1, "rate": 0]],
            "initializer": [["name": "sizerandom", "min": 100, "max": 100],
                            ["name": "lifetimerandom", "min": 10, "max": 10]],
        ]))
        let transform = WPEParticleSceneTransform(
            sceneSize: SIMD2(3840, 2160), objectOrigin: .zero,
            objectScale: SIMD3(0.1, 0.2, 1), objectAngleZ: 0
        )
        for refractive in [false, true] {
            let system = try #require(WPEParticleSystem(
                definition: definition, device: device, blendMode: .translucent,
                sceneTransform: transform, seed: 133
            ))
            system.isRefract = refractive
            system.tick(now: 0)
            system.tick(now: 0.05)
            try #require(system.liveInstanceCount == 1)
            let instance = system.instanceBuffer.contents().bindMemory(to: WPEParticleInstance.self, capacity: 4)[0]
            #expect(abs(instance.positionAndSize.w - 7.5) < 0.001)
        }
    }

    @Test("Perspective rain preserves its authored two-to-one horizontal emission extent")
    func rainEmissionExtent() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let definition = try #require(WPEParticleDefinitionParser.parse(dictionary: [
            "maxcount": 2048,
            "emitter": [["name": "sphererandom", "instantaneous": 2048, "rate": 0,
                         "directions": "2 1 1", "distancemin": 0, "distancemax": 1024]],
            "initializer": [["name": "lifetimerandom", "min": 10, "max": 10]],
        ]))
        let system = try #require(WPEParticleSystem(definition: definition, device: device, seed: 133))
        system.tick(now: 0)
        let particles = system.instanceBuffer.contents().bindMemory(to: WPEParticleInstance.self, capacity: 2048)
        var maxX: Float = 0
        var xSquare: Float = 0
        var zSquare: Float = 0
        for i in 0 ..< system.liveInstanceCount {
            let x = particles[i].positionAndSize.x + 0.5
            let y = particles[i].positionAndSize.y + 0.5
            let z = particles[i].velocity.w
            maxX = max(maxX, abs(x))
            xSquare += x * x
            zSquare += z * z
            #expect(x * x / 4 + y * y + z * z <= 1024 * 1024 + 1)
        }
        #expect(system.liveInstanceCount == 2048)
        #expect(maxX > 1800 && maxX <= 2048)
        #expect(xSquare / zSquare > 3.5 && xSquare / zSquare < 4.5)
    }

    @Test("Short-lived rain stays stable across render frame intervals", arguments: [15, 30, 60, 0])
    func rainPopulationAcrossFrameIntervals(fps: Int) throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let definition = try #require(WPEParticleDefinitionParser.parse(dictionary: [
            "maxcount": 4096,
            "emitter": [["name": "boxrandom", "rate": 2000]],
            "initializer": [["name": "lifetimerandom", "min": 0.31, "max": 0.31],
                            ["name": "velocityrandom", "min": "0 -3000 0", "max": "0 -3000 0"],
                            ["name": "alpharandom", "min": 1, "max": 1]],
            "operator": [["name": "alphafade", "fadeintime": 0.15, "fadeouttime": 0.15]],
        ]))
        let system = try #require(WPEParticleSystem(definition: definition, device: device, seed: 133))
        system.tick(now: 0)
        var now = 0.0
        var frame = 0
        let irregular = [0.08, 0.02, 0.06, 0.04]
        while now < 2 {
            now = min(2, now + (fps == 0 ? irregular[frame % irregular.count] : 1 / Double(fps)))
            system.tick(now: now)
            frame += 1
        }
        #expect((580 ... 640).contains(system.liveInstanceCount))
        let particles = system.instanceBuffer.contents().bindMemory(to: WPEParticleInstance.self, capacity: 4096)
        var meanAlpha: Float = 0
        var zeroAge = 0
        for i in 0 ..< system.liveInstanceCount {
            let fraction = particles[i].rotationAndLife.y
            if fraction < 0.00001 {
                zeroAge += 1
            }
            #expect(abs(particles[i].positionAndSize.y + 0.5 + 930 * fraction) < 0.01)
            meanAlpha += particles[i].color.w
        }
        meanAlpha /= Float(system.liveInstanceCount)
        #expect(zeroAge == 0)
        #expect(meanAlpha > 0.46 && meanAlpha < 0.56)
    }

    @Test("Resuming after a long gap keeps particle catch-up bounded")
    func resumeCatchUpRemainsBounded() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let system = try #require(WPEParticleSystem(definition: makeDefinition(), device: device, seed: 133))
        system.tick(now: 0)
        system.tick(now: 30)
        #expect(system.liveInstanceCount == 4)
        let particles = system.instanceBuffer.contents().bindMemory(to: WPEParticleInstance.self, capacity: 4)
        for i in 0 ..< system.liveInstanceCount {
            #expect(particles[i].rotationAndLife.y > 0)
            #expect(particles[i].rotationAndLife.y <= 0.01001)
        }
    }

    private func makeDefinition(
        originOffset: SIMD3<Double> = SIMD3(0, 0, 0),
        velocityMin: SIMD3<Double> = SIMD3(0, 0, 0),
        velocityMax: SIMD3<Double> = SIMD3(0, 0, 0),
        directionMask: SIMD3<Double> = SIMD3(1, 1, 1)
    ) -> WPEParticleDefinition {
        WPEParticleDefinition(
            materialRelativePath: nil,
            maxCount: 4,
            rate: 1000,
            startDelay: 0,
            lifetimeMin: 10, lifetimeMax: 10,
            sizeMin: 10, sizeMax: 10,
            originOffset: originOffset,
            dispersalMin: SIMD3<Double>(0, 0, 0), dispersalMax: SIMD3<Double>(0, 0, 0),
            velocityMin: velocityMin, velocityMax: velocityMax,
            colorMin: SIMD3(255, 255, 255), colorMax: SIMD3(255, 255, 255),
            fadeInSeconds: 0.01,
            directionMask: directionMask
        )
    }

    // MARK: - Scene-object Y-up (no flip)

    @Test("Scene-object origin centers without Y-flip (Y-up bottom-left)")
    func sceneObjectOriginCentersWithoutFlip() throws {
        let transform = WPEParticleSceneTransform(
            sceneSize: SIMD2<Float>(3840, 2160),
            objectOrigin: SIMD3<Float>(0, 0, 0),
            objectScale: SIMD3<Float>(1, 1, 1),
            objectAngleZ: 0
        )
        #expect(abs(transform.renderOrigin.x - (-1920)) < 0.0001)
        #expect(abs(transform.renderOrigin.y - (-1080)) < 0.0001)
    }

    @Test("Fog-shape origin (1997, 440) lands in lower half (NDC y < 0)")
    func fogOriginInLowerHalf() {
        let transform = WPEParticleSceneTransform(
            sceneSize: SIMD2<Float>(4216, 2416),
            objectOrigin: SIMD3<Float>(1997, 440, 0),
            objectScale: SIMD3<Float>(1, 1, 1),
            objectAngleZ: 0
        )
        #expect(transform.renderOrigin.y < 0)
        #expect(abs(transform.renderOrigin.y - (-768)) < 0.01)
    }

    // MARK: - Emitter local Y-down (flips applied at spawn)

    @Test("angles.z rotates as authored (+angleZ), matching the image-layer quad")
    func angleZMatchesImageLayer() {
        let transform = WPEParticleSceneTransform(
            sceneSize: SIMD2<Float>(1920, 1080),
            objectOrigin: SIMD3<Float>(960, 540, 0),
            objectScale: SIMD3<Float>(1, 1, 1),
            objectAngleZ: .pi * 0.5
        )
        let p = transform.applyModelMatrix(toLocalPoint: SIMD3<Float>(1, 0, 0))
        #expect(abs(p.x) < 0.0001)
        #expect(abs(p.y - 1) < 0.0001)
    }

    @Test("applyModelDirection rotates without translating")
    func directionApplyHasNoTranslation() {
        let transform = WPEParticleSceneTransform(
            sceneSize: SIMD2<Float>(1920, 1080),
            objectOrigin: SIMD3<Float>(960, 540, 0),
            objectScale: SIMD3<Float>(2, 3, 1),
            objectAngleZ: 0
        )
        let v = transform.applyModelDirection(SIMD3<Float>(10, -7, 0))
        #expect(abs(v.x - 20) < 0.0001)
        #expect(abs(v.y - (-21)) < 0.0001)
    }

    @Test("Object scale enlarges sprite size (T·R·S) and spreads the emitter")
    func sceneObjectScaleAffectsEmitterAndSpriteSize() {
        let transform = WPEParticleSceneTransform(
            sceneSize: SIMD2<Float>(1920, 1080),
            objectOrigin: SIMD3<Float>(0, 0, 0),
            objectScale: SIMD3<Float>(3, 3, 1),
            objectAngleZ: 0
        )
        #expect(abs(transform.worldSizeMultiplier() - 3) < 0.0001)
        let spread = transform.applyModelDirection(SIMD3<Float>(10, 0, 0))
        #expect(abs(spread.x - 30) < 0.0001)
    }

    @Test("Emitter origin is used as authored — Y-up, no flip")
    func emitterOriginIsNotYFlipped() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let def = makeDefinition(originOffset: SIMD3(100, 200, 0))
        let transform = WPEParticleSceneTransform(
            sceneSize: SIMD2<Float>(1920, 1080),
            objectOrigin: SIMD3<Float>(1000, 540, 0),
            objectScale: SIMD3<Float>(1, 1, 1),
            objectAngleZ: 0
        )
        let system = try #require(WPEParticleSystem(
            definition: def,
            device: device,
            blendMode: .translucent,
            sceneTransform: transform
        ))
        system.tick(now: 0)
        system.tick(now: 0.05)
        #expect(system.liveInstanceCount > 0)
        let inst = system.instanceBuffer.contents()
            .bindMemory(to: WPEParticleInstance.self, capacity: 4)[0]
        #expect(abs(inst.positionAndSize.x - 140) < 0.5)
        #expect(abs(inst.positionAndSize.y - 200) < 0.5)
    }

    @Test("Velocity is used as authored — Y-up, no flip (negative vy drifts down)")
    func velocityIsNotYFlipped() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let def = makeDefinition(
            originOffset: SIMD3(0, 0, 0),
            velocityMin: SIMD3(0, -50, 0),
            velocityMax: SIMD3(0, -50, 0)
        )
        let transform = WPEParticleSceneTransform(
            sceneSize: SIMD2<Float>(1920, 1080),
            objectOrigin: SIMD3<Float>(960, 540, 0),
            objectScale: SIMD3<Float>(1, 1, 1),
            objectAngleZ: 0
        )
        let system = try #require(WPEParticleSystem(
            definition: def,
            device: device,
            blendMode: .translucent,
            sceneTransform: transform
        ))
        for step in 1...5 {
            system.tick(now: Double(step) * 0.05)
        }
        let inst = system.instanceBuffer.contents()
            .bindMemory(to: WPEParticleInstance.self, capacity: 4)[0]
        #expect(inst.positionAndSize.y < -5)
    }

    @Test("Rotated emitter sends negative-vy leaves UP (3725117707 case)")
    func rotatedEmitterInvertsVerticalDrift() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let def = makeDefinition(
            originOffset: SIMD3(0, 0, 0),
            velocityMin: SIMD3(0, -50, 0),
            velocityMax: SIMD3(0, -50, 0)
        )
        let transform = WPEParticleSceneTransform(
            sceneSize: SIMD2<Float>(4216, 2416),
            objectOrigin: SIMD3<Float>(2108, 1208, 0),
            objectScale: SIMD3<Float>(3, 3, 1),
            objectAngleZ: 2.77231
        )
        let system = try #require(WPEParticleSystem(
            definition: def,
            device: device,
            blendMode: .translucent,
            sceneTransform: transform
        ))
        for step in 1...5 {
            system.tick(now: Double(step) * 0.05)
        }
        let inst = system.instanceBuffer.contents()
            .bindMemory(to: WPEParticleInstance.self, capacity: 4)[0]
        #expect(inst.positionAndSize.y > 5)
    }

    @Test("Gravity follows scene object scale and rotation like velocity")
    func gravityUsesSceneObjectDirectionTransform() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let def = WPEParticleDefinition(
            materialRelativePath: nil,
            maxCount: 1,
            rate: 1000,
            startDelay: 0,
            lifetimeMin: 10,
            lifetimeMax: 10,
            sizeMin: 1,
            sizeMax: 1,
            originOffset: SIMD3(0, 0, 0),
            dispersalMin: SIMD3<Double>(0, 0, 0),
            dispersalMax: SIMD3<Double>(0, 0, 0),
            velocityMin: SIMD3(0, 0, 0),
            velocityMax: SIMD3(0, 0, 0),
            colorMin: SIMD3(255, 255, 255),
            colorMax: SIMD3(255, 255, 255),
            fadeInSeconds: 0.01,
            gravity: SIMD3(10, 0, 0)
        )
        let transform = WPEParticleSceneTransform(
            sceneSize: SIMD2<Float>(1920, 1080),
            objectOrigin: SIMD3<Float>(960, 540, 0),
            objectScale: SIMD3<Float>(-1, 1, 1),
            objectAngleZ: 0
        )
        let system = try #require(WPEParticleSystem(
            definition: def,
            device: device,
            blendMode: .translucent,
            sceneTransform: transform
        ))

        system.tick(now: 0)
        system.tick(now: 0.05)
        let initialX = system.instanceBuffer.contents()
            .bindMemory(to: WPEParticleInstance.self, capacity: 1)[0].positionAndSize.x
        system.tick(now: 0.15)
        let laterX = system.instanceBuffer.contents()
            .bindMemory(to: WPEParticleInstance.self, capacity: 1)[0].positionAndSize.x

        #expect(laterX < initialX)
    }

    @Test("Particle sprite carries scene object mirror signs and rotation")
    func particleSpriteCarriesObjectMirrorAndRotation() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let def = WPEParticleDefinition(
            materialRelativePath: nil,
            maxCount: 1,
            rate: 1000,
            startDelay: 0,
            lifetimeMin: 10,
            lifetimeMax: 10,
            sizeMin: 1,
            sizeMax: 1,
            originOffset: SIMD3(0, 0, 0),
            dispersalMin: SIMD3<Double>(0, 0, 0),
            dispersalMax: SIMD3<Double>(0, 0, 0),
            velocityMin: SIMD3(0, 0, 0),
            velocityMax: SIMD3(0, 0, 0),
            colorMin: SIMD3(255, 255, 255),
            colorMax: SIMD3(255, 255, 255),
            fadeInSeconds: 0,
            rotationMin: SIMD3(0, 0, 0),
            rotationMax: SIMD3(0, 0, 0)
        )
        let transform = WPEParticleSceneTransform(
            sceneSize: SIMD2<Float>(1920, 1080),
            objectOrigin: SIMD3<Float>(960, 540, 0),
            objectScale: SIMD3<Float>(-1, 1, 1),
            objectAngleZ: 0.75
        )
        let system = try #require(WPEParticleSystem(
            definition: def,
            device: device,
            blendMode: .translucent,
            sceneTransform: transform
        ))

        system.tick(now: 0)
        system.tick(now: 0.05)
        let instance = system.instanceBuffer.contents()
            .bindMemory(to: WPEParticleInstance.self, capacity: 1)[0]

        #expect(instance.positionAndSize.z < 0)
        #expect(instance.rotationAndLife.w > 0)
        #expect(abs(instance.rotationAndLife.x - 0.75) < 0.001)
    }

    @Test("Parser captures directions mask")
    func parserCapturesDirections() throws {
        let json = #"""
        {
            "emitter": [{"rate": 1, "directions": "1 0.2 0"}],
            "initializer": [],
            "operator": []
        }
        """#
        let def = try #require(WPEParticleDefinitionParser.parse(data: Data(json.utf8)))
        #expect(abs(def.directionMask.x - 1) < 0.0001)
        #expect(abs(def.directionMask.y - 0.2) < 0.0001)
        #expect(abs(def.directionMask.z - 0) < 0.0001)
    }

    @Test("Sphere directions select active axes before independent axis scaling")
    func sphereSurfaceDirectionUsesUnitVariance() {
        var requestedStddevs: [Double] = []
        let normal = WPEParticleSystem.sphereSurfaceDirection(directions: SIMD3<Double>(3, 4, 0)) { mean, stddev in
            #expect(mean == 0)
            requestedStddevs.append(stddev)
            return stddev
        }
        #expect(requestedStddevs == [1, 1], "the disabled Z axis must not be sampled")
        #expect(abs(normal.x - 1 / sqrt(2)) < 0.0001)
        #expect(abs(normal.y - 1 / sqrt(2)) < 0.0001)
        #expect(abs(normal.z) < 0.0001)
    }

    @Test("Sphere surface direction with all axes disabled returns zero instead of dividing by zero")
    func sphereSurfaceDirectionZeroVectorGuard() {
        let normal = WPEParticleSystem.sphereSurfaceDirection(directions: SIMD3<Double>(0, 0, 0)) { _, stddev in stddev }
        #expect(normal == SIMD3<Double>(0, 0, 0))
    }

    @Test("Sphere surface direction with a single enabled axis always lands on ±that axis")
    func sphereSurfaceDirectionSingleAxisIsAlwaysUnitOnThatAxis() {
        let positive = WPEParticleSystem.sphereSurfaceDirection(directions: SIMD3<Double>(0, 0, 5)) { _, _ in 2.5 }
        #expect(positive == SIMD3<Double>(0, 0, 1))
        let negative = WPEParticleSystem.sphereSurfaceDirection(directions: SIMD3<Double>(0, 0, 5)) { _, _ in -2.5 }
        #expect(negative == SIMD3<Double>(0, 0, -1))
    }

    @Test("Sphere radius sampling is volume-uniform: lerp(pow(rand, 1/3), min, max), not naive lerp(rand, min, max)")
    func sphereRadiusIsVolumeUniform() {
        let r = WPEParticleSystem.sphereRadius(min: 0, max: 100, uniform01: 0.5)
        #expect(abs(r - 100 * pow(0.5, 1.0 / 3.0)) < 0.0001)
        #expect(r > 75, "volumetric bias should skew well past the naive-uniform midpoint of 50 (got \(r))")

        #expect(abs(WPEParticleSystem.sphereRadius(min: 10, max: 90, uniform01: 0) - 10) < 0.0001)
        #expect(abs(WPEParticleSystem.sphereRadius(min: 10, max: 90, uniform01: 1) - 90) < 0.0001)
    }

    @Test("Direction mask zero collapses dispersal on that axis")
    func directionMaskZeroCollapsesAxis() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let radiused = WPEParticleDefinition(
            materialRelativePath: nil,
            maxCount: 4,
            rate: 1000, startDelay: 0,
            lifetimeMin: 10, lifetimeMax: 10,
            sizeMin: 1, sizeMax: 1,
            originOffset: SIMD3(0, 0, 0),
            dispersalMin: SIMD3<Double>(100, 100, 100), dispersalMax: SIMD3<Double>(100, 100, 100),
            velocityMin: SIMD3(0, 0, 0), velocityMax: SIMD3(0, 0, 0),
            colorMin: SIMD3(255, 255, 255), colorMax: SIMD3(255, 255, 255),
            fadeInSeconds: 0.01,
            directionMask: SIMD3(1, 0, 0)
        )
        let transform = WPEParticleSceneTransform(
            sceneSize: SIMD2<Float>(1920, 1080),
            objectOrigin: SIMD3<Float>(960, 540, 0),
            objectScale: SIMD3<Float>(1, 1, 1),
            objectAngleZ: 0
        )
        let system = try #require(WPEParticleSystem(
            definition: radiused,
            device: device,
            blendMode: .translucent,
            sceneTransform: transform
        ))
        system.tick(now: 0)
        system.tick(now: 0.05)
        let instances = system.instanceBuffer.contents()
            .bindMemory(to: WPEParticleInstance.self, capacity: 4)
        for index in 0..<system.liveInstanceCount {
            #expect(abs(instances[index].positionAndSize.y) < 0.01)
        }
    }
}
