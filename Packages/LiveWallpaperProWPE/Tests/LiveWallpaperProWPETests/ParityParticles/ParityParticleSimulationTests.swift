@testable import LiveWallpaperProWPE
import simd
import XCTest

final class ParityParticleSimulationTests: XCTestCase {
    private func system(_ text: String, rng: WPEParityMT19937 = WPEParityMT19937()) -> WPEParityParticleSystem {
        WPEParityParticleSystem(json: ParityParticleTestSupport.json(text), rng: rng)
    }

    func testDyingParticleFreesItsSlotForThisFramesEmitAndNewbornMoves() {
        var particles = system("""
        {"maxcount": 1,
         "emitter": [{"name": "sphererandom", "rate": 20, "distancemax": 0}],
         "initializer": [{"name": "lifetimerandom", "min": 0.05, "max": 0.05},
                         {"name": "velocityrandom", "min": "10 0 0", "max": "10 0 0"}],
         "operator": [{"name": "movement"}]}
        """)
        particles.advance(dt: 0.1)
        XCTAssertEqual(particles.liveCount, 1)
        XCTAssertEqual(particles.age[0], 0)
        XCTAssertEqual(particles.position[0].x, 1, accuracy: 1e-6)
        particles.advance(dt: 0.1)
        // The first particle (age 0.1 > 0.05) dies before this frame's emit, which reuses slot 0.
        XCTAssertEqual(particles.liveCount, 1)
        XCTAssertEqual(particles.age[0], 0)
        XCTAssertEqual(particles.position[0].x, 1, accuracy: 1e-6)
        XCTAssertEqual(particles.lifetime.count, 1)
    }

    func testOperatorsResetToInitialValuesEveryStep() {
        var particles = system("""
        {"maxcount": 1,
         "emitter": [{"name": "sphererandom", "rate": 0, "instantaneous": 1, "distancemax": 0}],
         "initializer": [{"name": "lifetimerandom", "min": 10, "max": 10}],
         "operator": [{"name": "sizechange", "startvalue": 1, "endvalue": 0},
                      {"name": "sizechange", "startvalue": 1, "endvalue": 0}]}
        """)
        particles.advance(dt: 1)
        // t = 0 on the birth frame: both ramps are 1 and the birth size is 0.5.
        XCTAssertEqual(particles.size[0], 0.5)
        particles.advance(dt: 5)
        // t = 0.5: two sizechange entries multiply once each, from the reset initial size.
        XCTAssertEqual(particles.size[0], 0.5 * 0.5 * 0.5, accuracy: 1e-6)
        particles.advance(dt: 0.5)
        XCTAssertEqual(particles.size[0], 0.5 * 0.45 * 0.45, accuracy: 1e-6)
    }

    func testStartTimePrewarmStepDependsOnMaxCount() {
        let small = system("""
        {"maxcount": 100, "starttime": 0.12,
         "emitter": [{"name": "sphererandom", "rate": 10}]}
        """)
        XCTAssertEqual(small.prewarmStep, 0.05)
        XCTAssertEqual(small.prewarmStepCount, 3)
        XCTAssertEqual(small.liveCount, 1)

        let large = system("""
        {"maxcount": 500, "starttime": 0.3,
         "emitter": [{"name": "sphererandom", "rate": 10}]}
        """)
        XCTAssertEqual(large.prewarmStep, 0.2)
        XCTAssertEqual(large.prewarmStepCount, 2)
        XCTAssertEqual(large.liveCount, 4)
    }

    func testBurstIsClampedToMaxCountAndExcessIsDropped() {
        var particles = system("""
        {"maxcount": 10,
         "emitter": [{"name": "sphererandom", "rate": 0, "instantaneous": 50}],
         "initializer": [{"name": "lifetimerandom", "min": 0.05, "max": 0.05}]}
        """)
        particles.advance(dt: 0.01)
        XCTAssertEqual(particles.liveCount, 10)
        particles.advance(dt: 0.1)
        XCTAssertEqual(particles.liveCount, 0)
        particles.advance(dt: 0.1)
        XCTAssertEqual(particles.liveCount, 0)
    }

    func testDelayAndDurationGateEmission() {
        var particles = system("""
        {"maxcount": 100,
         "emitter": [{"name": "sphererandom", "rate": 4, "delay": 0.5, "duration": 0.5}],
         "initializer": [{"name": "lifetimerandom", "min": 100, "max": 100}]}
        """)
        particles.advance(dt: 0.25)
        particles.advance(dt: 0.25)
        XCTAssertEqual(particles.liveCount, 0)
        for _ in 0 ..< 10 {
            particles.advance(dt: 0.25)
        }
        XCTAssertEqual(particles.liveCount, 2)
    }

    func testEveryEmitterRuns() {
        var particles = system("""
        {"maxcount": 100,
         "emitter": [{"name": "sphererandom", "rate": 10}, {"name": "boxrandom", "rate": 20}]}
        """)
        particles.advance(dt: 0.1)
        XCTAssertEqual(particles.liveCount, 3)
    }

    func testInstanceRateScalesTheFrameStep() {
        var particles = WPEParityParticleSystem(
            json: ParityParticleTestSupport.json("""
            {"maxcount": 100, "emitter": [{"name": "sphererandom", "rate": 10}],
             "initializer": [{"name": "lifetimerandom", "min": 100, "max": 100}]}
            """),
            instanceOverride: WPESceneParticleInstanceOverride(rate: 2),
            rng: WPEParityMT19937()
        )
        particles.advance(dt: 0.1)
        XCTAssertEqual(particles.liveCount, 2)
        XCTAssertEqual(particles.age[0], 0)
        particles.advance(dt: 0.1)
        XCTAssertEqual(particles.liveCount, 4)
        XCTAssertEqual(particles.age[0], 0.2)
    }

    func testUnknownComponentsAreReported() {
        let particles = system("""
        {"maxcount": 1,
         "initializer": [{"name": "remapinitialvalue"}, {"name": "inheritinitialvaluefromevent"}],
         "operator": [{"name": "remapvalue"}, {"name": "inheritvaluefromevent"}, {"name": "collisionquad"},
                      {"name": "collisionplane", "collisionbehavior": "slide"}, {"name": "movement"}]}
        """)
        for name in ["collisionquad", "collisionplane (slide)"] {
            XCTAssertTrue(particles.diagnostics.contains { $0.contains(name) }, name)
        }
        for name in ["movement", "remapinitialvalue", "inheritinitialvaluefromevent", "remapvalue",
                     "inheritvaluefromevent"] {
            XCTAssertFalse(particles.diagnostics.contains { $0.contains(name) }, name)
        }
        XCTAssertEqual(particles.config.initializers.count, 2)
        XCTAssertEqual(particles.config.operators.count, 3)
    }

    func testEventDeathChildSpawnsAtTheDeathPosition() {
        let child = """
        {"maxcount": 4, "emitter": [{"name": "sphererandom", "rate": 0, "instantaneous": 4, "distancemax": 0}],
         "initializer": [{"name": "lifetimerandom", "min": 1, "max": 1}]}
        """
        var particles = WPEParityParticleSystem(
            json: ParityParticleTestSupport.json("""
            {"maxcount": 1,
             "emitter": [{"name": "sphererandom", "rate": 0, "instantaneous": 1, "distancemax": 0}],
             "initializer": [{"name": "lifetimerandom", "min": 0.05, "max": 0.05},
                             {"name": "velocityrandom", "min": "10 0 0", "max": "10 0 0"}],
             "operator": [{"name": "movement"}],
             "children": [{"name": "child.json", "type": "eventdeath", "probability": 1}]}
            """),
            rng: WPEParityMT19937(),
            resolveChild: { $0 == "child.json" ? ParityParticleTestSupport.json(child) : nil }
        )
        particles.advance(dt: 0.1)
        XCTAssertEqual(particles.eventChildren[0].count, 0)
        particles.advance(dt: 0.1)
        XCTAssertEqual(particles.liveCount, 0)
        XCTAssertEqual(particles.eventChildren[0].count, 1)
        let spawned = particles.eventChildren[0][0]
        XCTAssertEqual(spawned.liveCount, 4)
        XCTAssertEqual(spawned.position[0].x, 1, accuracy: 1e-6)
    }

    func testDeathPrewarmInheritsTheOldSlotAndDrawsBeforeTheRebornParent() throws {
        let child = ParityParticleTestSupport.json("""
        {"maxcount": 1, "starttime": 0.05,
         "emitter": [{"name": "boxrandom", "rate": 0, "instantaneous": 1,
                      "distancemin": "1 1 1", "distancemax": "1 1 1", "directions": "1 1 1"}],
         "initializer": [{"name": "lifetimerandom", "min": 10, "max": 10},
                         {"name": "inheritinitialvaluefromevent", "input": "setcolor"},
                         {"name": "inheritinitialvaluefromevent", "input": "setvelocity"},
                         {"name": "remapinitialvalue", "operation": "remap", "input": "layertime", "output": "size"},
                         {"name": "remapinitialvalue", "operation": "remap", "input": "particlesystemtime", "output": "opacity"}]}
        """)
        let rng = WPEParityMT19937(seed: 7)
        var particles = WPEParityParticleSystem(json: ParityParticleTestSupport.json("""
        {"maxcount": 1,
         "emitter": [{"name": "boxrandom", "rate": 10, "distancemin": "1 1 1",
                      "distancemax": "1 1 1", "directions": "1 1 1"}],
         "initializer": [{"name": "lifetimerandom", "min": 0.05, "max": 0.05}],
         "children": [{"name": "child.json", "type": "eventdeath", "probability": 1}]}
        """), rng: rng, resolveChild: { _ in child })
        particles.advance(dt: 0.1)
        particles.color[0] = SIMD3(1, 0, 0)
        particles.initialColor[0] = SIMD3(1, 0, 0)
        particles.velocity[0] = SIMD3(10, 0, 0)

        // Independent finite draw schedule: each box birth takes u, three offset values, speed and lifetime.
        // Frame one parent: 6 words; death probability: 1; child prewarm birth: 6; reborn parent: 6.
        let expected = WPEParityMT19937(seed: 7)
        for _ in 0 ..< 6 {
            _ = expected.next()
        }
        _ = expected.unit()
        let childU = expected.unit()
        for _ in 0 ..< 5 {
            _ = expected.next()
        }
        let parentU = expected.unit()
        for _ in 0 ..< 5 {
            _ = expected.next()
        }
        particles.advance(dt: 0.1)
        let spawned = try XCTUnwrap(particles.eventChildren[0].first)
        XCTAssertEqual(spawned.prewarmStepCount, 1)
        XCTAssertEqual(spawned.initialColor[0], SIMD3(1, 0, 0), "Birth must read the dying slot before emit reuses it")
        XCTAssertEqual(spawned.velocity[0], SIMD3(10, 0, 0))
        XCTAssertEqual(particles.initialColor[0], SIMD3(repeating: 1))
        XCTAssertEqual(particles.velocity[0], .zero)
        XCTAssertEqual(spawned.birthU[0], childU)
        XCTAssertEqual(particles.birthU[0], parentU)
        XCTAssertEqual(rng.next(), expected.next(), "The next object must see the same shared MT continuation")
        XCTAssertEqual(spawned.initialSize[0], 0.2, accuracy: 1e-6, "Event prewarm reads the current owner layer time")
        XCTAssertEqual(spawned.initialAlpha[0], 0, "Construction prewarm does not advance system elapsed")
        XCTAssertEqual(spawned.simulationTime, 0.1, accuracy: 1e-6)
        XCTAssertEqual(spawned.objectTime, 0.2, accuracy: 1e-6)
        XCTAssertEqual(particles.liveCount, 1)
        XCTAssertEqual(particles.lifetime.count, 1)
    }

    private func boxEvents(_ entries: String, count: Int = 1, continuous: Bool = false,
                           childLifetime: Float = 10, prewarm: Bool = true) -> WPEParityParticleSystem {
        let child = ParityParticleTestSupport.json("""
        {"maxcount": 1, "starttime": \(prewarm ? 0.05 : 0),
         "emitter": [{"name": "boxrandom", "rate": 0, "instantaneous": 1,
                      "distancemin": "1 1 1", "distancemax": "1 1 1", "directions": "1 1 1"}],
         "initializer": [{"name": "lifetimerandom", "min": \(childLifetime), "max": \(childLifetime)}]}
        """)
        return WPEParityParticleSystem(json: ParityParticleTestSupport.json("""
        {"maxcount": \(count),
         "emitter": [{"name": "boxrandom", "rate": \(continuous ? 10 : 0), "instantaneous": \(continuous ? 0 : count),
                      "distancemin": "1 1 1", "distancemax": "1 1 1", "directions": "1 1 1"}],
         "initializer": [{"name": "lifetimerandom", "min": 0.05, "max": 0.05}],
         "children": [\(entries)]}
        """), rng: WPEParityMT19937(seed: 7), resolveChild: { _ in child })
    }

    func testDeathZeroRemainingSkipsProbabilityAndFullSingleGroupStopsFurtherEvents() {
        var zero = boxEvents(#"{"name": "a", "type": "eventdeath", "maxcount": 0}"#)
        zero.advance(dt: 0.1)
        zero.advance(dt: 0.1)
        XCTAssertTrue(zero.eventChildren[0].isEmpty)
        let zeroExpected = WPEParityMT19937(seed: 7)
        for _ in 0 ..< 6 {
            _ = zeroExpected.next()
        }
        XCTAssertEqual(zero.rng.next(), zeroExpected.next(), "No remaining room means no probability draw")

        var full = boxEvents(#"{"name": "a", "type": "eventdeath", "maxcount": 1}"#, continuous: true)
        for _ in 0 ..< 3 {
            full.advance(dt: 0.1)
        }
        XCTAssertEqual(full.eventChildren[0].count, 1)
        // Three parent births, one probability and one child prewarm birth: 3*6 + 1 + 6 = 25.
        let fullExpected = WPEParityMT19937(seed: 7)
        for _ in 0 ..< 25 {
            _ = fullExpected.next()
        }
        XCTAssertEqual(full.rng.next(), fullExpected.next())
    }

    func testTwoDeathCapsFollowTheNativeEqualityBranchInsteadOfConventionalClamping() {
        var particles = boxEvents("""
        {"name": "a", "type": "eventdeath", "maxcount": 1, "probability": 1},
        {"name": "b", "type": "eventdeath", "maxcount": 1, "probability": 1}
        """, count: 2)
        particles.advance(dt: 0.1)
        particles.advance(dt: 0.1)
        // Dead parent 0: A reaches 1 and skips B. Dead parent 1: A reaches 2 (!=1), then B reaches 1.
        XCTAssertEqual(particles.eventChildren.map(\.count), [2, 1])
        let expected = WPEParityMT19937(seed: 7)
        for _ in 0 ..< 12 {
            _ = expected.next()
        }
        var childU: [Float] = []
        for _ in 0 ..< 3 {
            _ = expected.unit()
            childU.append(expected.unit())
            for _ in 0 ..< 5 {
                _ = expected.next()
            }
        }
        XCTAssertEqual(particles.eventChildren[0].map { $0.birthU[0] }, Array(childU.prefix(2)))
        XCTAssertEqual(particles.eventChildren[1][0].birthU[0], childU[2])
        XCTAssertEqual(particles.rng.next(), expected.next())
    }

    func testSpawnGroupsApplyProbabilityAndStopAtTheDefaultTenBeforeParentOperators() {
        var particles = boxEvents("""
        {"name": "a", "type": "eventspawn", "maxcount": 0},
        {"name": "b", "type": "eventspawn", "probability": 0},
        {"name": "c", "type": "eventspawn"}
        """, count: 12)
        particles.advance(dt: 0.1)
        XCTAssertEqual(particles.eventChildren.map(\.count), [0, 0, 10])
        let expected = WPEParityMT19937(seed: 7)
        for _ in 0 ..< 72 {
            _ = expected.next()
        } // All 12 parent births precede all child groups.
        for _ in 0 ..< 12 {
            _ = expected.next()
        } // Group A draws none; group B takes 12 rejected probabilities.
        var childU: [Float] = []
        for _ in 0 ..< 10 {
            _ = expected.unit()
            childU.append(expected.unit())
            for _ in 0 ..< 5 {
                _ = expected.next()
            }
        }
        XCTAssertEqual(particles.eventChildren[2].map { $0.birthU[0] }, childU)
        XCTAssertEqual(particles.rng.next(), expected.next())
    }

    /// 30 births a second, each spawning a three-particle event child that lives 0.3 s.
    private static func eventSpawningSystem() -> WPEParityParticleSystem {
        let child = """
        {"maxcount": 4, "emitter": [{"name": "sphererandom", "rate": 0, "instantaneous": 3, "distancemax": 5}],
         "initializer": [{"name": "lifetimerandom", "min": 0.3, "max": 0.3},
                         {"name": "velocityrandom", "min": "-20 -20 0", "max": "20 20 0"}],
         "operator": [{"name": "movement"}], "renderer": [{"name": "sprite"}]}
        """
        return WPEParityParticleSystem(
            json: ParityParticleTestSupport.json("""
            {"maxcount": 20,
             "emitter": [{"name": "sphererandom", "rate": 30, "distancemax": 10}],
             "initializer": [{"name": "lifetimerandom", "min": 0.5, "max": 0.5},
                             {"name": "velocityrandom", "min": "-5 -5 0", "max": "5 5 0"}],
             "operator": [{"name": "movement"}], "renderer": [{"name": "sprite"}],
             "children": [{"name": "child.json", "type": "eventspawn"}]}
            """),
            rng: WPEParityMT19937(seed: 7),
            resolveChild: { $0 == "child.json" ? ParityParticleTestSupport.json(child) : nil }
        )
    }

    /// Base addresses of every array the system and its children keep between frames.
    private static func buffers(_ system: WPEParityParticleSystem) -> Set<UInt> {
        func address(_ array: [some Any]) -> UInt {
            array.withUnsafeBufferPointer { UInt(bitPattern: $0.baseAddress) }
        }
        var addresses: Set<UInt> = [
            address(system.position), address(system.velocity), address(system.rotation),
            address(system.angularVelocity), address(system.color), address(system.initialColor),
            address(system.alpha), address(system.initialAlpha), address(system.size), address(system.initialSize),
            address(system.age), address(system.lifetime), address(system.birthU), address(system.frame),
            address(system.previousPosition), address(system.birthNext), address(system.birthPrevious),
            address(system.trailPoints), address(system.trailCount), address(system.trailHead),
            address(system.mainBytes), address(system.ropeBytes), address(system.ropeTrailBytes),
            address(system.pendingEvents), address(system.emitterStates), address(system.sequenceStates),
            address(system.controlPoints), address(system.previousControlPoints),
        ]
        for group in system.eventChildren + system.finishedEventChildren {
            addresses.insert(address(group))
            for child in group {
                addresses.formUnion(buffers(child))
            }
        }
        for child in system.children {
            addresses.formUnion(buffers(child))
        }
        return addresses
    }

    func testSteadyStateFramesKeepEveryBufferOfTheSystemAndItsEventChildren() {
        var particles = Self.eventSpawningSystem()
        var warm: Set<UInt> = []
        for frame in 1 ... 300 {
            particles.advance(dt: 1.0 / 60)
            let count = particles.drawBatches(objectID: "5").count
            if frame == 150 {
                warm = Self.buffers(particles)
            } else if frame > 150 {
                XCTAssertGreaterThan(count, 1, "frame \(frame)")
                XCTAssertEqual(Self.buffers(particles), warm, "frame \(frame)")
            }
        }
    }

    /// Isolate the draw consumer with an already-instantiated tree. The JSON gate still rejects event children
    /// with descendants until the real product draw block and lifecycle are integrated.
    func testDrawTraversalCompletesEachEventSubtreeAndCarriesItsOwnMatrix() {
        let leaf = ParityParticleTestSupport.json("""
        {"maxcount": 1, "emitter": [{"name": "sphererandom", "rate": 0, "instantaneous": 1, "distancemax": 0}],
         "initializer": [{"name": "lifetimerandom", "min": 10, "max": 10}], "renderer": [{"name": "sprite"}]}
        """)
        let json = ParityParticleTestSupport.json("""
        {"maxcount": 1, "emitter": [{"name": "sphererandom", "rate": 0, "instantaneous": 1, "distancemax": 0}],
         "initializer": [{"name": "lifetimerandom", "min": 10, "max": 10}], "renderer": [{"name": "sprite"}],
         "children": [{"name": "leaf", "origin": "5 0 0"}]}
        """)
        let config = WPEParityParticleConfig(json: json, is3D: false) { $0 == "leaf" ? leaf : nil }
        let rng = WPEParityMT19937(seed: 7)
        let crt = WPEParityCRTRandom()
        var instances: [WPEParityParticleSystem] = []
        for x in [Float(-20), Float(20)] {
            var transform = matrix_identity_float4x4
            transform.columns.3.x = x
            var instance = WPEParityParticleSystem(config: config, instance: .init(), rng: rng, crt: crt,
                                                   localTransform: transform)
            instance.advance(dt: 0.1)
            instances.append(instance)
        }
        var parent = system(#"{"maxcount": 0}"#, rng: rng)
        parent.eventChildren = [instances]
        let batches = parent.drawBatches(objectID: "5")
        XCTAssertEqual(batches.map(\.key.passIdentity), ["5/particle/e0/r0", "5/particle/e0/0/r0",
                                                         "5/particle/e0/r0", "5/particle/e0/0/r0"])
        XCTAssertEqual(batches.map(\.localTransform.columns.3.x), [-20, -15, 20, 25])
        XCTAssertEqual(batches.map(\.vertices.count), [1, 1, 1, 1])
        XCTAssertNotEqual(WPEParityParticleDrawKey(objectID: "5", path: [.eventGroup(0), .staticChild(0)], renderer: 0),
                          WPEParityParticleDrawKey(objectID: "5", node: [0], renderer: 0, eventGroup: 0))
    }

    func testFinishedEventReuseKeepsTheFiniteBirthDrawSequenceAndResetsOldValues() {
        var particles = boxEvents(#"{"name": "a", "type": "eventspawn"}"#, continuous: true,
                                  childLifetime: 0.05, prewarm: false)
        let expected = WPEParityMT19937(seed: 7)
        for frame in 1 ... 5 {
            let parentU = expected.unit()
            for _ in 0 ..< 5 {
                _ = expected.next()
            }
            _ = expected.unit() // Spawn probability.
            let childU = expected.unit()
            for _ in 0 ..< 5 {
                _ = expected.next()
            }
            particles.advance(dt: 0.1)
            XCTAssertEqual(particles.birthU[0], parentU)
            XCTAssertEqual(particles.eventChildren[0].count, 1)
            let child = particles.eventChildren[0][0]
            XCTAssertEqual(child.birthU[0], childU, "frame \(frame)")
            XCTAssertEqual(child.color[0], SIMD3(repeating: 1))
            XCTAssertEqual(child.velocity[0], .zero)
            if frame > 1 {
                XCTAssertEqual(particles.eventChildConstructions, 2)
            }
            particles.eventChildren[0][0].color[0] = SIMD3(3, 2, 1)
            particles.eventChildren[0][0].velocity[0] = SIMD3(9, 8, 7)
        }
        XCTAssertEqual(particles.rng.next(), expected.next())
    }

    func testCapVelocityDefaultsTo100In2DAnd1In3D() {
        for (is3D, cap) in [(false, Float(100)), (true, Float(1))] {
            var particles = WPEParityParticleSystem(
                json: ParityParticleTestSupport.json("""
                {"maxcount": 1,
                 "emitter": [{"name": "sphererandom", "rate": 0, "instantaneous": 1, "distancemax": 0,
                              "speedmin": 0, "speedmax": 0}],
                 "initializer": [{"name": "lifetimerandom", "min": 10, "max": 10},
                                 {"name": "velocityrandom", "min": "200 0 0", "max": "200 0 0"}],
                 "operator": [{"name": "capvelocity"}]}
                """),
                rng: WPEParityMT19937(),
                is3D: is3D
            )
            particles.advance(dt: 0.1)
            XCTAssertEqual(simd_length(particles.velocity[0]), cap, accuracy: cap * 1e-5, "is3D \(is3D)")
        }
    }

    func testTimingThousandParticleSphereSystem() {
        var particles = system("""
        {"maxcount": 1000,
         "emitter": [{"name": "sphererandom", "rate": 1000, "distancemax": 50, "speedmin": 10, "speedmax": 20}],
         "initializer": [{"name": "lifetimerandom", "min": 1, "max": 1}],
         "operator": [{"name": "movement", "gravity": "0 -10 0", "drag": 0.1},
                      {"name": "alphafade"}, {"name": "sizechange"}]}
        """)
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0 ..< 600 {
            particles.advance(dt: 1.0 / 60)
        }
        let milliseconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
        print(String(format: "particle timing: 1000 sphererandom, 600 frames, %.1f ms", milliseconds))
        XCTAssertGreaterThan(particles.liveCount, 900)
    }

    func testTimingThousandParticleSphereSystemWithTurbulence() {
        var particles = system("""
        {"maxcount": 1000,
         "emitter": [{"name": "sphererandom", "rate": 1000, "distancemax": 50, "speedmin": 10, "speedmax": 20}],
         "initializer": [{"name": "lifetimerandom", "min": 1, "max": 1}],
         "operator": [{"name": "movement", "gravity": "0 -10 0", "drag": 0.1},
                      {"name": "alphafade"}, {"name": "sizechange"}, {"name": "turbulence"}]}
        """)
        let start = DispatchTime.now().uptimeNanoseconds
        for frame in 0 ..< 600 {
            particles.advance(dt: 1.0 / 60, frame: WPEParityParticleFrameContext(time: Float(frame) / 60))
        }
        let milliseconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
        print(String(format: "particle timing: 1000 sphererandom + turbulence, 600 frames, %.1f ms", milliseconds))
        XCTAssertGreaterThan(particles.liveCount, 900)
    }
}
