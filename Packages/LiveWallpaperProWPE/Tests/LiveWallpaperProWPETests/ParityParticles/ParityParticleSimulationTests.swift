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
                      {"name": "collisionsphere", "collisionbehavior": "slide"}, {"name": "movement"}]}
        """)
        for name in ["collisionquad", "collisionsphere (slide)"] {
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
        XCTAssertEqual(spawned.position[0].x, 0, accuracy: 1e-6)
        XCTAssertEqual(spawned.instanceTransform.columns.3.x, 1, accuracy: 1e-6)
        XCTAssertEqual((spawned.instanceTransform * SIMD4(spawned.position[0], 1)).x, 1, accuracy: 1e-6)
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
         "children": [{"name": "child.json", "type": "eventdeath", "probability": 1, "origin": "3 5 0",
                       "angles": "0 0 1.5707963267948966", "scale": "-2 3 1"}]}
        """), rng: rng, resolveChild: { _ in child })
        particles.advance(dt: 0.1)
        particles.color[0] = SIMD3(1, 0, 0)
        particles.initialColor[0] = SIMD3(1, 0, 0)
        particles.velocity[0] = SIMD3(10, 0, 0)

        // Native finite draw schedule: shape Z/Y/X, speed, birthU, lifetime (238bda → 23b372).
        // Frame one parent: 6 words; death probability: 1; child prewarm birth: 6; reborn parent: 6.
        let expected = WPEParityMT19937(seed: 7)
        for _ in 0 ..< 6 {
            _ = expected.next()
        }
        _ = expected.unit()
        for _ in 0 ..< 4 {
            _ = expected.next()
        }
        let childU = expected.unit() // Global word12, the fifth word of the child birth.
        _ = expected.next() // Child lifetime.
        for _ in 0 ..< 4 {
            _ = expected.next()
        }
        let parentU = expected.unit() // Global word18.
        _ = expected.next() // Reborn parent lifetime.
        particles.advance(dt: 0.1)
        let spawned = try XCTUnwrap(particles.eventChildren[0].first)
        XCTAssertEqual(spawned.prewarmStepCount, 1)
        XCTAssertEqual(spawned.initialColor[0], SIMD3(1, 0, 0), "Birth must read the dying slot before emit reuses it")
        XCTAssertEqual(spawned.velocity[0], SIMD3(10, 0, 0))
        XCTAssertEqual(spawned.instanceTransform.columns.0.y, -2, accuracy: 2e-6)
        XCTAssertEqual(spawned.instanceTransform.columns.1.x, -3, accuracy: 2e-6,
                       "reflected child TRS belongs to its model; inherited velocity stays in the parent raw basis")
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
            for _ in 0 ..< 4 {
                _ = expected.next()
            }
            childU.append(expected.unit()) // Global words18/25/32: shape3 + speed precede birthU.
            _ = expected.next() // Lifetime.
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
            for _ in 0 ..< 4 {
                _ = expected.next()
            }
            childU.append(expected.unit()) // Global word90 + 7*child, not the first birth word.
            _ = expected.next() // Lifetime.
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

    /// Isolate the walker with an already-instantiated tree; parsed N1 lifecycle is guarded separately.
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
                                                   instanceTransform: transform)
            instance.advance(dt: 0.1, frame: .init(objectMatrix: transform))
            instances.append(instance)
        }
        var parent = system(#"{"maxcount": 0}"#, rng: rng)
        parent.eventChildren = [instances]
        let batches = parent.drawBatches(objectID: "5")
        XCTAssertEqual(batches.map(\.key.passIdentity), ["5/particle/e0/r0", "5/particle/e0/0/r0",
                                                         "5/particle/e0/r0", "5/particle/e0/0/r0"])
        XCTAssertEqual(batches.map(\.modelMatrix.columns.3.x), [-20, -15, 20, 25])
        XCTAssertEqual(batches.map(\.vertices.count), [1, 1, 1, 1])
        XCTAssertNotEqual(WPEParityParticleDrawKey(objectID: "5", path: [.eventGroup(0), .staticChild(0)], renderer: 0),
                          WPEParityParticleDrawKey(objectID: "5", node: [0], renderer: 0, eventGroup: 0))
    }

    func testFinishedEventReuseKeepsTheFiniteBirthDrawSequenceAndResetsOldValues() {
        var particles = boxEvents(#"{"name": "a", "type": "eventspawn", "angles": "0 0 1.5707963267948966", "scale": "2 3 1"}"#, continuous: true,
                                  childLifetime: 0.05, prewarm: false)
        let expected = WPEParityMT19937(seed: 7)
        for frame in 1 ... 5 {
            for _ in 0 ..< 4 {
                _ = expected.next()
            }
            let parentU = expected.unit() // Per-frame word5.
            _ = expected.next() // Parent lifetime.
            _ = expected.unit() // Spawn probability.
            for _ in 0 ..< 4 {
                _ = expected.next()
            }
            let childU = expected.unit() // Per-frame word12.
            _ = expected.next() // Child lifetime.
            particles.advance(dt: 0.1)
            XCTAssertEqual(particles.birthU[0], parentU)
            XCTAssertEqual(particles.eventChildren[0].count, 1)
            let child = particles.eventChildren[0][0]
            XCTAssertEqual(child.instanceTransform.columns.0.y, 2, accuracy: 2e-6)
            XCTAssertEqual(child.instanceTransform.columns.1.x, -3, accuracy: 2e-6,
                           "fresh and finished spawn reuse must both use the authored TRS once")
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

    private func nestedDeathSystem(trs: Bool = false) -> WPEParityParticleSystem {
        let leaf = ParityParticleTestSupport.json("""
        {"maxcount": 1, "starttime": 0.09,
         "emitter": [{"name": "boxrandom", "rate": 0, "instantaneous": 1, "origin": "2 0 0",
                      "distancemin": "0 0 0", "distancemax": "0 0 0", "directions": "1 1 1"}],
         "initializer": [{"name": "lifetimerandom", "min": 0.085, "max": 0.085},
                         {"name": "velocityrandom", "min": "10 0 0", "max": "10 0 0"},
                         {"name": "remapinitialvalue", "input": "distancetocontrolpoint", "output": "size",
                          "operation": "remap", "inputrangemax": 4, "outputrangemax": 4}],
         "operator": [{"name": "movement"}]}
        """)
        let event = ParityParticleTestSupport.json("""
        {"maxcount": 1,
         "emitter": [{"name": "boxrandom", "rate": 0, "instantaneous": 1, "origin": "2 0 0",
                      "distancemin": "0 0 0", "distancemax": "0 0 0", "directions": "1 1 1"}],
         "initializer": [{"name": "lifetimerandom", "min": 0.015, "max": 0.015},
                         {"name": "velocityrandom", "min": "10 0 0", "max": "10 0 0"}],
         "operator": [{"name": "movement"}], "children": [{"name": "leaf", "origin": "\(trs ? "0 2 0" : "5 0 0")"}]}
        """)
        let json = ParityParticleTestSupport.json("""
        {"maxcount": 1,
         "emitter": [{"name": "boxrandom", "rate": 100, "distancemin": "0 0 0", "distancemax": "0 0 0",
                      "directions": "1 1 1"}],
         "initializer": [{"name": "lifetimerandom", "min": 0.005, "max": 0.005}],
         "children": [{"name": "event", "type": "eventdeath", "origin": "\(trs ? "5 0 0" : "3 0 0")", "maxcount": 1
                       \(trs ? #", "angles": "0 0 -1.5707963267948966", "scale": "1 3 1""# : "")}]}
        """)
        let config = WPEParityParticleConfig(json: json, is3D: false) { $0 == "event" ? event : leaf }
        return WPEParityParticleSystem(config: config, instance: .init(), rng: WPEParityMT19937(seed: 7),
                                       crt: WPEParityCRTRandom(), context: nestedDeathFrame(trs: trs))
    }

    private func nestedDeathFrame(trs: Bool) -> WPEParityParticleFrameContext {
        // Independent owner W=T4*Rz90*S(2,1), supplied at every 230650 object-update boundary.
        let ancestor = simd_float4x4(SIMD4(0, 2, 0, 0), SIMD4(-1, 0, 0, 0),
                                     SIMD4(0, 0, 1, 0), SIMD4(4, 0, 0, 1))
        return WPEParityParticleFrameContext(objectMatrix: trs ? ancestor : matrix_identity_float4x4)
    }

    func testLocalNestedDeathPlacementReusePrewarmFullStepAndSharedRNG() throws {
        for trs in [false, true] {
            try assertLocalNestedDeathPlacementReusePrewarmFullStepAndSharedRNG(trs: trs)
        }
    }

    private func assertLocalNestedDeathPlacementReusePrewarmFullStepAndSharedRNG(trs: Bool) throws {
        var parent = nestedDeathSystem(trs: trs)
        let frame = nestedDeathFrame(trs: trs)
        parent.advance(dt: 0.01, frame: frame)
        parent.position[0] = SIMD3(trs ? 3 : -20, 0, 0)
        parent.advance(dt: 0.01, frame: frame)
        let first = try XCTUnwrap(parent.eventChildren[0].first)
        let leaf = try XCTUnwrap(first.children.first)
        if trs {
            // 22a360 stores E=T(raw3)*T5*Rz-90*S(1,3); 229760 pushes U=A*E.
            XCTAssertEqual(first.instanceTransform.columns.3.x, 8, accuracy: 2e-6)
            XCTAssertEqual(first.instanceTransform.columns.3.y, 0, accuracy: 2e-6)
            XCTAssertEqual(first.frameContext.objectMatrix.columns.3.y, 16, accuracy: 2e-6)
            // Static E=T(0,2) stays authored; U=A*Eevent*Estatic has translation (4,28), basis diag(1,6).
            XCTAssertEqual(leaf.instanceTransform.columns.3, SIMD4(0, 2, 0, 1))
            XCTAssertEqual(leaf.frameContext.objectMatrix.columns.3.x, 4, accuracy: 2e-6)
            XCTAssertEqual(leaf.frameContext.objectMatrix.columns.3.y, 28, accuracy: 2e-6)
            XCTAssertEqual(leaf.frameContext.objectMatrix.columns.0.x, 1, accuracy: 2e-6)
            XCTAssertEqual(leaf.frameContext.objectMatrix.columns.1.y, 6, accuracy: 2e-6)
        } else {
            XCTAssertEqual(first.instanceTransform.columns.3.x, -17)
            XCTAssertEqual(leaf.instanceTransform.columns.3, SIMD4(5, 0, 0, 1))
            XCTAssertEqual(leaf.frameContext.objectMatrix.columns.3.x, -12)
        }
        XCTAssertEqual(first.position[0].x, 2.1, accuracy: 1e-5, "new event receives the full 0.01, not the 0.005 remaining after death")
        XCTAssertEqual(leaf.position[0].x, 3.1, accuracy: 1e-5, "two constructor steps then the full parent step")
        XCTAssertEqual(leaf.age[0], 0.06, accuracy: 1e-6)
        XCTAssertEqual(leaf.initialSize[0], 2, accuracy: 1e-6, "CP distance uses local birth x=2, not event x=-20")
        XCTAssertEqual(first.simulationTime, 0.01)
        XCTAssertEqual(leaf.simulationTime, 0.01)
        XCTAssertEqual(leaf.objectTime, 0.02)
        parent.advance(dt: 0.01, frame: frame)
        parent.advance(dt: 0.01, frame: frame)
        XCTAssertEqual(parent.eventChildren[0][0].liveCount, 0)
        XCTAssertEqual(parent.eventChildren[0][0].children[0].liveCount, 1,
                       "an empty event root stays active until its static leaf finishes")
        parent.advance(dt: 0.01, frame: frame)
        XCTAssertTrue(parent.eventChildren[0].isEmpty)
        XCTAssertEqual(parent.finishedEventChildren[0].count, 1)
        parent.position[0] = SIMD3(trs ? 7 : 20, 0, 0)
        parent.advance(dt: 0.01, frame: frame)
        let reused = try XCTUnwrap(parent.eventChildren[0].first)
        let reusedLeaf = try XCTUnwrap(reused.children.first)
        XCTAssertEqual(parent.eventChildConstructions, 1)
        if trs {
            XCTAssertEqual(reused.instanceTransform.columns.3.x, 12, accuracy: 2e-6)
            XCTAssertEqual(reused.instanceTransform.columns.3.y, 0, accuracy: 2e-6)
            XCTAssertEqual(reused.frameContext.objectMatrix.columns.3.y, 24, accuracy: 2e-6)
            XCTAssertEqual(reusedLeaf.instanceTransform.columns.3, SIMD4(0, 2, 0, 1))
            XCTAssertEqual(reusedLeaf.frameContext.objectMatrix.columns.3.x, 4, accuracy: 2e-6)
            XCTAssertEqual(reusedLeaf.frameContext.objectMatrix.columns.3.y, 36, accuracy: 2e-6,
                           "reuse must rebase from authored edges without compounding their TRS")
        } else {
            XCTAssertEqual(reused.instanceTransform.columns.3.x, 23)
            XCTAssertEqual(reusedLeaf.instanceTransform.columns.3, SIMD4(5, 0, 0, 1))
            XCTAssertEqual(reusedLeaf.frameContext.objectMatrix.columns.3.x, 28, "the new U composes unchanged static E once")
        }
        XCTAssertEqual(reusedLeaf.age[0], 0, "reuse prewarms only the event root, not static descendants")
        XCTAssertEqual(reusedLeaf.position[0].x, 2.1, accuracy: 1e-5)
        XCTAssertEqual(reusedLeaf.initialSize[0], 2, accuracy: 1e-6)
        XCTAssertEqual(reusedLeaf.objectTime, parent.objectTime)
        // Zero-offset box: shape3 + fallback3 + speed + birthU + lifetime = 9 words (2378a0:997–1007).
        // Event/leaf velocity adds 3. Frames: 9; (prob1 + leaf12 + parent9 + event12); 9; 9; 9;
        // (prob1 + parent9 + event12 + leaf12) = 104. The nonzero-offset fixture's 6-word path does not apply.
        let expected = WPEParityMT19937(seed: 7)
        for _ in 0 ..< 104 {
            _ = expected.next()
        }
        XCTAssertEqual(parent.rng.next(), expected.next(), "reuse adds no constructor/reset draws to the shared stream")
    }

    func testFinishedStaticResetPreservesSlotsAndCPHistoryAndDrawsNothing() throws {
        var parent = nestedDeathSystem()
        for _ in 0 ..< 5 {
            parent.advance(dt: 0.01)
        }
        var finished = try XCTUnwrap(parent.finishedEventChildren[0].first)
        XCTAssertTrue(finished.isFinished)
        finished.children[0].position[0] = SIMD3(91, 92, 93)
        finished.children[0].previousPosition[0] = SIMD3(81, 82, 83)
        finished.children[0].controlPoints[0].columns.3 = SIMD4(7, 8, 9, 1)
        finished.children[0].previousControlPoints[0].columns.3 = SIMD4(4, 5, 6, 1)
        finished.children[0].controlPointsSeeded = true
        finished.children[0].boidsFrame = 23
        let highWater = finished.children[0].highWater
        let expected = WPEParityMT19937(seed: 7)
        for _ in 0 ..< 70 {
            _ = expected.next()
        }
        finished.resetFinishedEventThroughStaticChildren()
        let leaf = finished.children[0]
        XCTAssertEqual(leaf.highWater, highWater)
        XCTAssertEqual(leaf.position[0], SIMD3(91, 92, 93))
        XCTAssertEqual(leaf.previousPosition[0], SIMD3(81, 82, 83))
        XCTAssertEqual(leaf.controlPoints[0].columns.3, SIMD4(7, 8, 9, 1))
        XCTAssertEqual(leaf.previousControlPoints[0].columns.3, SIMD4(4, 5, 6, 1))
        XCTAssertTrue(leaf.controlPointsSeeded)
        XCTAssertEqual(leaf.boidsFrame, 23)
        XCTAssertTrue(leaf.emitterStates[0].burstPending)
        XCTAssertEqual(leaf.emitterStates[0].accumulator, 0)
        XCTAssertEqual(leaf.simulationTime, 0)
        XCTAssertEqual(finished.rng.next(), expected.next())
        XCTAssertNil(parent.parentSample(slot: -1))
        XCTAssertNil(parent.parentSample(slot: parent.highWater))
    }

    func testHiddenResetDiscardsActiveEventTreesInsteadOfReusingThemAsFinished() {
        var parent = nestedDeathSystem()
        parent.advance(dt: 0.01)
        parent.advance(dt: 0.01)
        XCTAssertEqual(parent.eventChildConstructions, 1)
        XCTAssertEqual(parent.eventChildren[0][0].children[0].liveCount, 1)
        parent.reset()
        XCTAssertTrue(parent.eventChildren[0].isEmpty)
        XCTAssertTrue(parent.finishedEventChildren[0].isEmpty)
        parent.advance(dt: 0.01)
        parent.advance(dt: 0.01)
        XCTAssertEqual(parent.eventChildConstructions, 2, "hidden active trees are destroyed, so this event constructs and prewarms a fresh subtree")
        XCTAssertEqual(parent.eventChildren[0][0].children[0].age[0], 0.06, accuracy: 1e-6)
    }

    /// Nonzero boxes take six words per birth. The moving placement fixture uses zero offsets and their
    /// three-word direction fallback, plus three words for its velocity initializer: twelve parent words.
    private func followParent(_ entries: String, assets: [String: String], count: Int = 1,
                              rate: Float = 0, lifetime: Float = 0.15, moving: Bool = false) -> WPEParityParticleSystem {
        WPEParityParticleSystem(json: ParityParticleTestSupport.json("""
        {"maxcount": \(count),
         "emitter": [{"name": "boxrandom", "rate": \(rate), "instantaneous": \(rate == 0 ? count : 0),
                      "distancemin": "\(moving ? "0 0 0" : "1 1 1")", "distancemax": "\(moving ? "0 0 0" : "1 1 1")",
                      "directions": "1 1 1"}],
         "initializer": [{"name": "lifetimerandom", "min": \(lifetime), "max": \(lifetime)}
                         \(moving ? #", {"name": "velocityrandom", "min": "100 0 0", "max": "100 0 0"}"# : "")],
         "operator": [\(moving ? #"{"name": "movement"}"# : "")], "children": [\(entries)]}
        """), rng: WPEParityMT19937(seed: 7), resolveChild: { assets[$0].map(ParityParticleTestSupport.json) })
    }

    private func followChild(lifetime: Float = 10, startTime: Float = 0, extra: String = "") -> String {
        """
        {"maxcount": 1, "starttime": \(startTime),
         "emitter": [{"name": "boxrandom", "rate": 0, "instantaneous": 1,
                      "distancemin": "1 1 1", "distancemax": "1 1 1", "directions": "1 1 1"}],
         "initializer": [{"name": "lifetimerandom", "min": \(lifetime), "max": \(lifetime)}]\(extra)}
        """
    }

    func testFollowRefreshesAfterParentOperatorsAndDetachesBeforeTheRawSlotIsReborn() {
        let leaf = """
        {"maxcount": 4,
         "emitter": [{"name": "boxrandom", "rate": 10, "duration": 1, "origin": "2 0 0",
                      "distancemin": "0 0 0", "distancemax": "0 0 0", "directions": "1 1 1"}],
         "initializer": [{"name": "lifetimerandom", "min": 0.8, "max": 0.8},
                         {"name": "remapinitialvalue", "input": "distancetocontrolpoint", "output": "size",
                          "operation": "remap", "inputrangemax": 4, "outputrangemax": 4}]}
        """
        let follow = """
        {"maxcount": 4,
         "emitter": [{"name": "boxrandom", "rate": 10, "duration": 1,
                      "distancemin": "0 0 0", "distancemax": "0 0 0", "directions": "1 1 1"}],
         "initializer": [{"name": "lifetimerandom", "min": 0.8, "max": 0.8},
                         {"name": "inheritinitialvaluefromevent", "input": "setcolor"}],
         "operator": [{"name": "inheritvaluefromevent", "input": "setcolor"}],
         "children": [{"name": "leaf", "origin": "0 5 0", "angles": "0 0 -1.5707963267948966", "scale": "1 3 1"}]}
        """
        var parent = followParent(#"{"name": "follow", "type": "eventfollow", "origin": "3 0 0", "angles": "0 0 1.5707963267948966", "scale": "2 1 1", "maxcount": 2}"#,
                                  assets: ["follow": follow, "leaf": leaf], rate: 10, moving: true)
        parent.instance.color = SIMD3(1, 0, 0)
        parent.advance(dt: 0.1)
        XCTAssertEqual(parent.position[0].x, 10)
        XCTAssertEqual(parent.eventChildren[0][0].instanceTransform.columns.3.x, 13)
        XCTAssertEqual(parent.eventChildren[0][0].children[0].instanceTransform.columns.3, SIMD4(0, 5, 0, 1))
        XCTAssertEqual(parent.eventChildren[0][0].children[0].instanceTransform.columns.0.y, -1, accuracy: 2e-6)
        XCTAssertEqual(parent.eventChildren[0][0].children[0].instanceTransform.columns.1.x, 3, accuracy: 2e-6)
        XCTAssertEqual(parent.eventChildren[0][0].children[0].frameContext.objectMatrix.columns.3.x, 8, accuracy: 2e-6)
        XCTAssertEqual(parent.eventChildren[0][0].children[0].frameContext.objectMatrix.columns.0.x, 1, accuracy: 2e-6)
        XCTAssertEqual(parent.eventChildren[0][0].children[0].frameContext.objectMatrix.columns.1.y, 6, accuracy: 2e-6)
        parent.advance(dt: 0.1)
        XCTAssertEqual(parent.eventChildren[0][0].instanceTransform.columns.3.x, 23)
        XCTAssertEqual(parent.eventChildren[0][0].children[0].frameContext.objectMatrix.columns.3.x, 18, accuracy: 2e-6)
        parent.instance.color = SIMD3(0, 0, 1)
        parent.advance(dt: 0.1)
        XCTAssertEqual(parent.eventChildren[0][0].instanceTransform.columns.3.x, 23)
        XCTAssertEqual(parent.eventChildren[0][0].children[0].frameContext.objectMatrix.columns.3.x, 18, accuracy: 2e-6)
        XCTAssertEqual(parent.eventChildren[0][1].instanceTransform.columns.3.x, 13)
        XCTAssertEqual(parent.eventChildren[0][1].children[0].frameContext.objectMatrix.columns.3.x, 8, accuracy: 2e-6)
        parent.advance(dt: 0.1)
        XCTAssertEqual(parent.liveCount, 1)
        XCTAssertEqual(parent.capacity, 1, "follow references do not pin the physical slot")
        XCTAssertEqual(parent.position[0].x, 20)
        XCTAssertEqual(parent.eventChildren[0].count, 2)
        let old = parent.eventChildren[0][0], new = parent.eventChildren[0][1]
        XCTAssertEqual(old.parentSlot, -1)
        XCTAssertNil(old.parentSample, "old follow must never inherit from the new particle in the same slot")
        XCTAssertEqual(old.instanceTransform.columns.3.x, 23)
        XCTAssertEqual(old.children[0].frameContext.objectMatrix.columns.3.x, 18, accuracy: 2e-6)
        XCTAssertEqual(new.parentSlot, 0)
        XCTAssertEqual(new.instanceTransform.columns.3.x, 23)
        XCTAssertEqual(new.children[0].frameContext.objectMatrix.columns.3.x, 18, accuracy: 2e-6)
        XCTAssertEqual(old.color[0], SIMD3(1, 0, 0))
        XCTAssertEqual(new.color[0], SIMD3(0, 0, 1))
        for system in [old, old.children[0]] {
            XCTAssertEqual(system.liveCount, 2, "detach stops new births without killing the existing particles")
            XCTAssertTrue(system.emitterStates[0].disabled)
            XCTAssertGreaterThan(system.emitterStates[0].durationLeft, 0, "positive duration must not clear stop")
            XCTAssertEqual(system.age[0], 0.3, accuracy: 1e-6)
            XCTAssertEqual(system.simulationTime, 0.4, accuracy: 1e-6, "the complete parent dt continues after detach")
        }
        XCTAssertEqual(old.children[0].position[0].x, 2)
        XCTAssertEqual(old.children[0].initialSize[0], 2, "ordinary CP distance uses local SoA, not follow placement")
        XCTAssertEqual(parent.followReferences, [0: 1])
        // Zero-offset boxes take shape ZYX + fallback ZYX + speed + birthU + lifetime = nine words; parent velocity adds 3.
        // Frames: parent12 + probability1 + follow9 + leaf9; follow9 + leaf9; repeat both = 98.
        let expected = WPEParityMT19937(seed: 7)
        for _ in 0 ..< 98 {
            _ = expected.next()
        }
        XCTAssertEqual(parent.rng.next(), expected.next(), "relocation/detach/stop add no MT draws")
    }

    func testFollowReferenceMapPreservesTheNativeMultiGroupDeathResidue() {
        let entries = #"{"name": "a", "type": "eventfollow"}, {"name": "b", "type": "eventfollow"}"#
        var parent = followParent(entries, assets: ["a": followChild(lifetime: 0.15), "b": followChild(lifetime: 0.15)],
                                  lifetime: 0.05)
        parent.advance(dt: 0.1)
        XCTAssertEqual(parent.followReferences, [0: 2])
        parent.advance(dt: 0.1)
        XCTAssertEqual(parent.eventChildren.map { $0.first?.parentSlot }, [-1, -1])
        XCTAssertEqual(parent.followReferences, [0: 1], "one parent death decrements once then detaches all groups")
        parent.advance(dt: 0.1)
        XCTAssertEqual(parent.finishedEventChildren.map(\.count), [1, 1])
        XCTAssertEqual(parent.followReferences, [0: 1], "detached finishes do not release the residual count")
        parent.reset()
        XCTAssertTrue(parent.followReferences.isEmpty)
        XCTAssertEqual(parent.finishedEventChildren.map(\.count), [1, 1], "hidden clears refs but preserves finished pools")
        let expected = WPEParityMT19937(seed: 7)
        for _ in 0 ..< 20 {
            _ = expected.next()
        } // parent6 + two probabilities + two child births6.
        XCTAssertEqual(parent.rng.next(), expected.next())

        var early = followParent(entries, assets: ["a": followChild(lifetime: 0.05), "b": followChild(lifetime: 0.5)])
        early.advance(dt: 0.1)
        early.advance(dt: 0.1)
        XCTAssertGreaterThan(early.lifetime[0], 0)
        XCTAssertEqual(early.finishedEventChildren.map(\.count), [1, 0])
        XCTAssertEqual(early.followReferences, [0: 1], "attached finish releases immediately before the next group")
        early.advance(dt: 0.1)
        XCTAssertTrue(early.followReferences.isEmpty)
        XCTAssertEqual(early.eventChildren[1][0].parentSlot, -1)
    }

    func testFollowAndSpawnUseOneGroupOrderedBirthPhaseAndEmptyInstancesStillConsumeCap() {
        let child = followChild(startTime: 0.05)
        var parent = followParent("""
                                  {"name": "a", "type": "eventfollow", "maxcount": 2},
                                  {"name": "b", "type": "eventspawn", "maxcount": 1},
                                  {"name": "c", "type": "eventfollow", "probability": 0},
                                  {"name": "empty", "type": "eventfollow", "maxcount": 1}
                                  """, assets: ["a": child, "b": child, "c": child, "empty": #"{"maxcount": 0, "renderer": []}"#],
                                  count: 3, lifetime: 10)
        let expected = WPEParityMT19937(seed: 7)
        for _ in 0 ..< 18 {
            _ = expected.next()
        } // Every parent birth precedes any group probability/prewarm.
        var firstGroupU: [Float] = []
        for _ in 0 ..< 2 {
            _ = expected.unit()
            for _ in 0 ..< 4 {
                _ = expected.next()
            }
            firstGroupU.append(expected.unit()) // Global words24/31.
            _ = expected.next() // Lifetime.
        }
        _ = expected.unit()
        for _ in 0 ..< 4 {
            _ = expected.next()
        }
        let spawnU = expected.unit() // Global word38.
        _ = expected.next() // Lifetime.
        for _ in 0 ..< 4 {
            _ = expected.next()
        } // Three failed C probabilities, one empty instance probability.
        parent.advance(dt: 0.1)
        XCTAssertEqual(parent.eventChildren.map(\.count), [2, 1, 0, 0])
        XCTAssertEqual(parent.finishedEventChildren.map(\.count), [0, 0, 0, 1])
        XCTAssertEqual(parent.eventChildren[0].map { $0.birthU[0] }, firstGroupU)
        XCTAssertEqual(parent.eventChildren[1][0].birthU[0], spawnU)
        XCTAssertEqual(parent.followReferences, [0: 1, 1: 1], "empty follow registers after append then releases at normal finish")
        XCTAssertEqual(parent.rng.next(), expected.next(), "empty follow is not pruned early inside the birth loop")
    }

    func testFollowFinishedLIFOReuseResetsStaticEmissionWithoutConstructorPrewarmAndHiddenDestroysActive() {
        let leaf = followChild(lifetime: 0.18, startTime: 0.09)
        let child = followChild(lifetime: 0.15, startTime: 0.05,
                                extra: #", "children": [{"name": "leaf", "origin": "5 0 0", "angles": "0 0 -1.5707963267948966", "scale": "1 2 1"}]"#)
        var parent = followParent(#"{"name": "follow", "type": "eventfollow", "origin": "3 0 0", "angles": "0 0 1.5707963267948966", "scale": "-2 3 1", "maxcount": 2}"#,
                                  assets: ["follow": child, "leaf": leaf], count: 2, rate: 20)
        func positionAddress(_ child: WPEParityParticleSystem) -> UInt {
            child.position.withUnsafeBufferPointer { UInt(bitPattern: $0.baseAddress) }
        }
        parent.advance(dt: 0.1)
        let originalBuffers = parent.eventChildren[0].map(positionAddress)
        XCTAssertEqual(parent.eventChildren[0][0].children[0].age[0], 0.15, accuracy: 1e-6)
        // Seed7 first box XYZ signs are (+,-,-); reflected follow maps leaf origin5 to (0,-10,0).
        XCTAssertEqual(parent.eventChildren[0][0].children[0].frameContext.objectMatrix.columns.3.x, 4, accuracy: 2e-6)
        XCTAssertEqual(parent.eventChildren[0][0].children[0].frameContext.objectMatrix.columns.3.y, -11, accuracy: 2e-6)
        parent.advance(dt: 0.1)
        XCTAssertTrue(parent.eventChildren[0].isEmpty)
        XCTAssertTrue(parent.followReferences.isEmpty)
        XCTAssertEqual(parent.finishedEventChildren[0].map(\.parentSlot), [0, 1])
        parent.advance(dt: 0.1)
        XCTAssertEqual(parent.eventChildConstructions, 2)
        XCTAssertEqual(parent.eventChildren[0].map(positionAddress), Array(originalBuffers.reversed()))
        XCTAssertEqual(parent.eventChildren[0].map(\.parentSlot), [0, 1])
        XCTAssertEqual(parent.followReferences, [0: 1, 1: 1])
        for child in parent.eventChildren[0] {
            XCTAssertEqual(child.children[0].instanceTransform.columns.3, SIMD4(5, 0, 0, 1))
            XCTAssertEqual(child.children[0].instanceTransform.columns.0.y, -1, accuracy: 2e-6)
            XCTAssertEqual(child.children[0].instanceTransform.columns.1.x, 2, accuracy: 2e-6)
            XCTAssertEqual(child.children[0].frameContext.objectMatrix.columns.0.x, 3, accuracy: 2e-6)
            XCTAssertEqual(child.children[0].frameContext.objectMatrix.columns.1.y, -4, accuracy: 2e-6)
            XCTAssertEqual(child.prewarmStepCount, 1)
            XCTAssertEqual(child.children[0].prewarmStepCount, 0)
            XCTAssertEqual(child.children[0].age[0], 0, "finished reuse enables static emission but never constructor-prewarms it")
        }
        parent.reset()
        XCTAssertTrue(parent.eventChildren[0].isEmpty)
        XCTAssertTrue(parent.followReferences.isEmpty)
        XCTAssertTrue(parent.finishedEventChildren[0].isEmpty, "hidden active instances cannot become reusable finished instances")
        parent.advance(dt: 0.1)
        XCTAssertEqual(parent.eventChildConstructions, 4)
        XCTAssertEqual(parent.eventChildren[0][0].children[0].age[0], 0.15, accuracy: 1e-6)
        // Each wave: parent12 + two (probability1 + own6 + leaf6) = 38. Reuse reorders but adds no draws.
        let expected = WPEParityMT19937(seed: 7)
        for _ in 0 ..< 114 {
            _ = expected.next()
        }
        XCTAssertEqual(parent.rng.next(), expected.next())
    }

    func testEachDeathDetachesFollowEvenWhenTheDeathGroupsHaveNoRemainingCapacity() {
        var parent = followParent("""
        {"name": "follow", "type": "eventfollow", "maxcount": 2},
        {"name": "death", "type": "eventdeath", "maxcount": 1}
        """, assets: ["follow": followChild(), "death": followChild(startTime: 0.05)], count: 2, lifetime: 0.05)
        parent.advance(dt: 0.1)
        let expected = WPEParityMT19937(seed: 7)
        for _ in 0 ..< 26 {
            _ = expected.next()
        } // Parent12, follow probabilities2, follow normal births12.
        _ = expected.unit()
        for _ in 0 ..< 4 {
            _ = expected.next()
        }
        let deathU = expected.unit() // Global word32.
        _ = expected.next() // Lifetime.
        parent.advance(dt: 0.1)
        XCTAssertEqual(parent.eventChildren.map(\.count), [2, 1])
        XCTAssertEqual(parent.eventChildren[0].map(\.parentSlot), [-1, -1])
        XCTAssertTrue(parent.followReferences.isEmpty, "the second death marker must run despite remaining==0")
        XCTAssertEqual(parent.eventChildren[1][0].birthU[0], deathU)
        XCTAssertEqual(parent.eventChildren[1][0].age[0], 0.1, accuracy: 1e-6, "death prewarm precedes a complete normal child step")
        XCTAssertEqual(parent.rng.next(), expected.next())
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
