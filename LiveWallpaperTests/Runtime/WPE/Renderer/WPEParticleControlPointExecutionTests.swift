#if !LITE_BUILD
import Foundation
@testable import LiveWallpaper
import LiveWallpaperProWPE
import Metal
import Testing

@Suite("Windows-backed particle control point production and consumption")
struct WPEParticleControlPointExecutionTests {
    @Test func absenceOfAlphaFadeDoesNotInventALifetimeScaledBirthRamp() throws {
        let system = try makeSystem(rate: 0, burst: 1, controlPoint: 0, lifetime: 20)
        system.tick(now: 0)
        #expect(system.liveInstanceCount == 1)
        let vertex = system.instanceBuffer.contents().assumingMemoryBound(to: WPEParticleInstance.self).pointee
        #expect(vertex.color.w == 1)
        system.tick(now: 1.5)
        #expect(system.instanceBuffer.contents().assumingMemoryBound(to: WPEParticleInstance.self).pointee.color.w == 1)
    }

    @Test func emitterConsumesAuthoredLocalOrAbsoluteWorldControlPoint() throws {
        for (flags, expected) in [(0, SIMD3<Float>(30, 0, 0)), (2, SIMD3<Float>(-98, -64, 0))] {
            let system = try makeSystem(rate: 0, burst: 1, controlPoint: 5, controlFlags: flags)
            system.tick(now: 0)
            let identity = try #require(system.primaryLiveParticleIdentity)
            let snapshot = try #require(system.snapshot(for: identity))
            #expect(snapshot.position == expected)
        }
    }

    @Test func automaticBurstConsumesContinuousEmissionBudget() throws {
        // burst=4, rate=1, lifetime=20: 4 live at t=0.5/2.5/4.5, 5 at t=5.5, 6 at t=6.5.
        let system = try makeSystem(rate: 1, burst: 4, controlPoint: 0, lifetime: 20)
        for frame in 0 ... 390 {
            system.tick(now: Double(frame) / 60)
            if [30, 150, 270].contains(frame) {
                #expect(system.liveInstanceCount == 4)
            }
            if frame == 330 {
                #expect(system.liveInstanceCount == 5)
            }
            if frame == 390 {
                #expect(system.liveInstanceCount == 6)
            }
        }
    }

    @Test func selectedEmitterControlPointSurvivesBothDefinitionCopyHelpers() throws {
        let definition = try makeSystem(rate: 0, burst: 1, controlPoint: 5).definition
        #expect(definition.emitterControlPointID == 5)
        #expect(definition.applying(instanceOverride: .init(brightness: 2)).emitterControlPointID == 5)
        #expect(definition.offsettingOrigin(by: SIMD3(1, 2, 0)).emitterControlPointID == 5)
    }

    @Test func parentBroadcastCompactsLiveParticlesAndRetainsAnUnfilledPoint() throws {
        let (tree, parent, child) = try makeTree(kind: "static")
        for frame in 0 ... 390 {
            tree.tick(now: Double(frame) / 60)
        }
        let positions = parent.liveControlPointSourcePositions(limit: 3)
        try #require(positions.count == 2)
        #expect(child.controlPointPosition(5) == positions[0])
        #expect(child.controlPointPosition(6) == positions[1])
        var lastSecond: SIMD3<Float>?
        var crossed = false
        for frame in 391 ... 540 {
            let before = child.controlPointPosition(6)
            let priorCount = parent.liveInstanceCount
            tree.tick(now: Double(frame) / 60)
            if priorCount == 2, parent.liveInstanceCount == 1 {
                lastSecond = before
                crossed = true
            }
            if crossed {
                #expect(child.controlPointPosition(6) == lastSecond)
            }
        }
        #expect(crossed)
    }

    @Test func eventFollowBroadcastUsesRawParentModelCoordinates() throws {
        let (tree, parent, _) = try makeTree(kind: "eventfollow")
        for frame in 0 ... 270 {
            tree.tick(now: Double(frame) / 60)
        }
        let children = tree.bindings.filter { $0.system !== parent }
        try #require(children.count == 2)
        let raw = try #require(parent.liveControlPointSourcePositions(limit: 1).first)
        for child in children {
            #expect(child.system.controlPointPosition(5) == raw)
            #expect(child.system.instanceOriginOffset.x > 0)
        }
    }

    private func makeTree(kind: String) throws -> (WPEParticleInstanceCoordinator, WPEParticleSystem, WPEParticleSystem) {
        let parent = try makeSystem(rate: 0.5, burst: 0, controlPoint: 0, velocity: "16 0 0", lifetime: 6, duration: 4.1)
        let child = try makeSystem(rate: 1, burst: 1, controlPoint: 5)
        let root = WPEParticleTemplate(parent)
        root.children = [.init(reference: .init(relativePath: "child", type: kind, maxCount: 2,
                                                flagsRaw: 1, controlPointStartIndex: 5), template: WPEParticleTemplate(child))]
        let device = try #require(MTLCreateSystemDefaultDevice())
        return (WPEParticleInstanceCoordinator(templates: [root], device: device, seed: 41), parent, child)
    }

    private func makeSystem(rate: Double, burst: Int, controlPoint: Int, controlFlags: Int = 0,
                            velocity: String = "0 0 0", lifetime: Double = 10, duration: Double = 0) throws -> WPEParticleSystem {
        let definition = WPEParticleDefinitionParser.parse(dictionary: [
            "maxcount": 32,
            "controlpoint": [["id": 0, "offset": "0 0 0", "flags": 0],
                             ["id": 5, "offset": "30 0 0", "flags": controlFlags],
                             ["id": 6, "offset": "50 0 0", "flags": 0]],
            "emitter": [["name": "boxrandom", "rate": rate, "instantaneous": burst,
                         "controlpoint": controlPoint, "duration": duration]],
            "initializer": [["name": "lifetimerandom", "min": lifetime, "max": lifetime],
                            ["name": "velocityrandom", "min": velocity, "max": velocity]],
        ])
        let device = try #require(MTLCreateSystemDefaultDevice())
        return try #require(WPEParticleSystem(definition: definition, device: device,
                                              sceneTransform: WPEParticleSceneTransform(sceneSize: SIMD2(256, 128),
                                                                                        objectOrigin: SIMD3(128, 64, 0),
                                                                                        objectScale: SIMD3(repeating: 1), objectAngleZ: 0), seed: 64))
    }
}
#endif
