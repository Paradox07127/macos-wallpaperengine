@testable import LiveWallpaperProWPE
import simd
import XCTest

final class ParityParticleFieldOperatorTests: XCTestCase {
    private typealias Support = ParityParticleTestSupport
    private typealias System = WPEParityParticleSystem

    func testNativePlaneSlideStopAndDeletePreserveTheirDistinctWrites() throws {
        let cases: [(name: String, position: SIMD3<Float>, velocity: SIMD3<Float>, deletes: Bool)] = [
            ("slide", .zero, SIMD3(1, 0, 3), false),
            ("stop", .zero, .zero, false),
            ("delete", SIMD3(0, -2, 0), SIMD3(1, -4, 3), true),
            ("unknown", .zero, SIMD3(1, 2, 3), false),
            ("SLIDE", .zero, SIMD3(1, 2, 3), false),
        ]
        for sample in cases {
            for flags in [0, 2] {
                var system = System(json: Support.json("""
                {"maxcount":1,"emitter":[{"name":"sphererandom","rate":0,"instantaneous":1,
                  "distancemax":0,"origin":"0 -2 0"}],
                 "initializer":[{"name":"lifetimerandom","min":100,"max":100},
                   {"name":"velocityrandom","min":"1 -4 3","max":"1 -4 3"},
                   {"name":"angularvelocityrandom","min":"2 4 6","max":"2 4 6"}],
                 "operator":[{"name":"collisionplane","plane":"0 1 0","distance":0,
                   "bouncefactor":0.5,"collisionbehavior":"\(sample.name)","flags":\(flags)}],
                 "renderer":[{"name":"spritetrail"}]}
                """), rng: WPEParityMT19937(seed: 7), is3D: true)
                system.advance(dt: 0.25)
                XCTAssertEqual(system.liveCount, 1, "Delete only writes age in this frame")
                assertEqual(system.position[0], sample.position)
                assertEqual(system.velocity[0], sample.velocity)
                assertEqual(system.angularVelocity[0], flags == 2 ? .zero : SIMD3(2, 4, 6))
                XCTAssertEqual(system.age[0], sample.deletes ? system.lifetime[0] : 0)
                let batch = try XCTUnwrap(system.drawBatches(objectID: "5").first)
                for axis in 0 ..< 3 {
                    XCTAssertEqual(Support.float(batch.vertices.bytes, at: axis * 4), sample.position[axis],
                                   accuracy: 1e-6)
                    XCTAssertEqual(Support.float(batch.vertices.bytes, at: 28 + axis * 4), sample.velocity[axis],
                                   accuracy: 1e-6)
                }
                XCTAssertTrue(system.diagnostics.isEmpty)
            }
        }
    }

    /// Native delete keeps this frame's draw and lets the next ordinary age pass generate real death events.
    func testCollisionDeleteStaysPackedUntilNextExpiryThenSpawnsDeathChild() throws {
        let child = Support.json("""
        {"maxcount":1,"emitter":[{"name":"sphererandom","rate":0,"instantaneous":1,"distancemax":0}],
         "initializer":[{"name":"lifetimerandom","min":100,"max":100},
           {"name":"inheritinitialvaluefromevent","input":"setvelocity"}],
         "renderer":[{"name":"spritetrail"}]}
        """)
        var parent = System(json: Support.json("""
        {"maxcount":1,"emitter":[{"name":"sphererandom","rate":0,"instantaneous":1,
          "distancemax":0,"origin":"0 -2 0"}],
         "initializer":[{"name":"lifetimerandom","min":1,"max":1},
           {"name":"velocityrandom","min":"1 -4 3","max":"1 -4 3"}],
         "operator":[{"name":"collisionplane","plane":"0 1 0","distance":0,"collisionbehavior":"delete"}],
         "children":[{"name":"child.json","type":"eventdeath"}],"renderer":[{"name":"spritetrail"}]}
        """), rng: WPEParityMT19937(seed: 7), is3D: true, resolveChild: { _ in child })
        parent.advance(dt: 0.25)
        XCTAssertEqual(parent.liveCount, 1)
        XCTAssertEqual(parent.age[0], parent.lifetime[0])
        XCTAssertTrue(try XCTUnwrap(parent.eventChildren.first).isEmpty)
        XCTAssertEqual(try XCTUnwrap(parent.drawBatches(objectID: "5").first).vertices.count, 1)
        parent.advance(dt: 0.125)
        XCTAssertEqual(parent.liveCount, 0)
        let spawned = try XCTUnwrap(parent.eventChildren.first?.first)
        XCTAssertEqual(spawned.liveCount, 1)
        assertEqual(spawned.velocity[0], SIMD3(1, -4, 3))
        let batch = try XCTUnwrap(spawned.drawBatches(objectID: "5").first)
        XCTAssertEqual(Support.floats(batch.vertices.bytes, at: 28, count: 3), [1, -4, 3])
    }

    /// The original strict contact mask clears angular velocity only for flags2, before the next operator.
    func testCollisionPlaneFlagTwoClearsOnlyAngularVelocityOnStrictContactBeforePacking() throws {
        let cases: [(flags: Int, originY: Int, angular: SIMD3<Float>, velocity: SIMD3<Float>)] = [
            (0, -2, SIMD3(2, 4, 6), SIMD3(1, 2, 3)),
            (2, -2, .zero, SIMD3(1, 2, 3)),
            (2, 0, SIMD3(2, 4, 6), SIMD3(1, -4, 3)),
        ]
        for sample in cases {
            var system = System(json: Support.json("""
            {"maxcount":1,"emitter":[{"name":"sphererandom","rate":0,"instantaneous":1,
              "distancemax":0,"origin":"0 \(sample.originY) 0"}],
             "initializer":[{"name":"lifetimerandom","min":100,"max":100},
               {"name":"velocityrandom","min":"1 -4 3","max":"1 -4 3"},
               {"name":"angularvelocityrandom","min":"2 4 6","max":"2 4 6"}],
             "operator":[{"name":"collisionplane","plane":"0 1 0","distance":0,
               "bouncefactor":0.5,"flags":\(sample.flags)}, {"name":"angularmovement"}],
             "renderer":[{"name":"spritetrail"}]}
            """), rng: WPEParityMT19937(seed: 7), is3D: true)
            system.advance(dt: 0.25)
            XCTAssertEqual(system.liveCount, 1)
            assertEqual(system.angularVelocity[0], sample.angular)
            assertEqual(system.velocity[0], sample.velocity)
            assertEqual(system.rotation[0], sample.angular * 0.25)
            system.advance(dt: 0.25)
            assertEqual(system.angularVelocity[0], sample.angular)
            assertEqual(system.rotation[0], sample.angular * 0.5)
            let batch = try XCTUnwrap(system.drawBatches(objectID: "5").first)
            for axis in 0 ..< 3 {
                XCTAssertEqual(Support.float(batch.vertices.bytes, at: 12 + axis * 4), sample.angular[axis] * 0.5,
                               accuracy: 1e-6)
                XCTAssertEqual(Support.float(batch.vertices.bytes, at: 28 + axis * 4), sample.velocity[axis],
                               accuracy: 1e-6)
            }
            let expected = WPEParityMT19937(seed: 7)
            for _ in 0 ..< 15 {
                _ = expected.next()
            }
            XCTAssertEqual(system.rng.next(), expected.next())
        }
    }

    /// `count` particles at the origin with lifetime 100 and no operators; tests then place them by hand.
    private func particles(count: Int = 1, maxCount: Int? = nil, extra: String = "",
                           flags: Int = 0, controlPoint: Int = 0) -> System {
        var system = System(
            json: Support.json("""
            {"maxcount": \(maxCount ?? count), "flags": \(flags),
             "emitter": [{"name": "sphererandom", "rate": 0, "instantaneous": \(count), "distancemax": 0,
                          "controlpoint": \(controlPoint)}],
             "initializer": [{"name": "lifetimerandom", "min": 100, "max": 100}]\(extra)}
            """),
            rng: WPEParityMT19937(), is3D: true
        )
        system.advance(dt: 0.001)
        XCTAssertEqual(system.liveCount, count)
        return system
    }

    private func entry(_ text: String) -> WPEParityParticleEntry {
        WPEParityParticleEntry(Support.json(text))
    }

    private func place(_ system: inout System, _ slot: Int, at position: SIMD3<Float>, velocity: SIMD3<Float> = .zero) {
        system.position[slot] = position
        system.velocity[slot] = velocity
    }

    private func assertEqual(
        _ actual: SIMD3<Float>, _ expected: SIMD3<Float>, accuracy: Float = 1e-5, line: UInt = #line
    ) {
        for axis in 0 ..< 3 {
            XCTAssertEqual(actual[axis], expected[axis], accuracy: accuracy, "axis \(axis)", line: line)
        }
    }

    func testVortexSwirlsAlongNormalCrossAxisWithClampedSpeed() {
        let field = WPEParityParticleVortex(entry(#"{"speedinner": 4, "speedouter": 2}"#), is3D: true)
        var system = particles()
        // r = 1.5 between inner 1 and outer 2: s = 0.5, speed 3; n × a = (1,0,0) × (0,0,1) = (0,-1,0).
        place(&system, 0, at: SIMD3(1.5, 0, 0))
        system.applyVortex(field, slot: 0, weight: 1, dt: 0.1)
        assertEqual(system.velocity[0], SIMD3(0, -0.3, 0))
        place(&system, 0, at: SIMD3(5, 0, 0))
        system.applyVortex(field, slot: 0, weight: 1, dt: 0.1)
        assertEqual(system.velocity[0], SIMD3(0, -0.2, 0))
        place(&system, 0, at: SIMD3(0, 0.5, 0))
        system.applyVortex(field, slot: 0, weight: 1, dt: 0.1)
        // n = (0,1,0): n × a = (1,0,0), inner speed 4.
        assertEqual(system.velocity[0], SIMD3(0.4, 0, 0))
    }

    func testVortexFlagOneDropsTheAxialComponentAndAddsTheOffset() {
        let field = WPEParityParticleVortex(
            entry(#"{"speedinner": 4, "speedouter": 2, "flags": 1, "offset": "1 0 0"}"#), is3D: true
        )
        var system = particles()
        system.controlPoints[0] = System.translation(SIMD3(0, 0, -3))
        place(&system, 0, at: SIMD3(2.5, 0, 7))
        system.applyVortex(field, slot: 0, weight: 1, dt: 0.1)
        assertEqual(system.velocity[0], SIMD3(0, -0.3, 0))
    }

    func testVortexRingKeepsTheNextStepRadiusWithCenterForce() {
        let field = WPEParityParticleVortexRing(
            entry(#"{"speedinner": 0, "speedouter": 0, "flags": 2, "centerforce": 1}"#), is3D: true
        )
        var system = particles()
        place(&system, 0, at: SIMD3(2, 0, 0), velocity: SIMD3(0, 10, 0))
        system.applyVortexRing(field, slot: 0, weight: 1, dt: 0.1)
        let next = system.position[0] + system.velocity[0] * 0.1
        XCTAssertEqual(simd_length(next), 2, accuracy: 1e-5)
    }

    func testAttractFallsOffToZeroAtThreshold() {
        let field = WPEParityParticleAttract(entry(#"{"scale": 10, "threshold": 4, "flags": 0}"#), is3D: true)
        var system = particles()
        place(&system, 0, at: SIMD3(2, 0, 0))
        system.applyAttract(field, slot: 0, weight: 1, dt: 0.1)
        // f = dt·scale·(1 − d/threshold) = 0.1·10·0.5.
        assertEqual(system.velocity[0], SIMD3(-0.5, 0, 0))
        place(&system, 0, at: SIMD3(3.9, 0, 0))
        system.applyAttract(field, slot: 0, weight: 1, dt: 0.1)
        assertEqual(system.velocity[0], SIMD3(-0.025, 0, 0))
        place(&system, 0, at: SIMD3(4, 0, 0))
        system.applyAttract(field, slot: 0, weight: 1, dt: 0.1)
        XCTAssertEqual(system.velocity[0], .zero)
    }

    func testAttractFlagTwoCapsTheStepAtTheDistance() {
        let field = WPEParityParticleAttract(entry(#"{"scale": 100, "threshold": 4}"#), is3D: true)
        XCTAssertEqual(field.flags, 2)
        var system = particles()
        place(&system, 0, at: SIMD3(0, 0.2, 0))
        system.applyAttract(field, slot: 0, weight: 1, dt: 0.1)
        // 0.1·100·0.95 = 9.5 is capped to the distance 0.2.
        assertEqual(system.velocity[0], SIMD3(0, -0.2, 0))
    }

    func testAttractDeleteFlagEndsParticlesWhosePathPassesThePoint() {
        let field = WPEParityParticleAttract(
            entry(#"{"threshold": 0.0001, "deletethreshold": 0.5, "flags": 1}"#), is3D: true
        )
        var system = particles()
        system.previousPosition[0] = SIMD3(-3, 0.3, 0)
        place(&system, 0, at: SIMD3(3, 0.3, 0))
        system.applyAttract(field, slot: 0, weight: 1, dt: 0.1)
        XCTAssertEqual(system.age[0], system.lifetime[0])

        var far = particles()
        far.previousPosition[0] = SIMD3(-3, 0.6, 0)
        place(&far, 0, at: SIMD3(3, 0.6, 0))
        far.applyAttract(field, slot: 0, weight: 1, dt: 0.1)
        XCTAssertLessThan(far.age[0], far.lifetime[0])
    }

    private func boidsPair(maxCount: Int, frame: Int) -> System {
        let field = WPEParityParticleBoids(
            entry(#"{"separationthreshold": 0.5, "neighborthreshold": 2, "flags": 0}"#), is3D: true
        )
        var system = particles(count: 2, maxCount: maxCount)
        place(&system, 0, at: .zero)
        place(&system, 1, at: SIMD3(1, 0, 0), velocity: SIMD3(0, 2, 0))
        system.boidsFrame = frame
        system.applyBoids(field, blend: nil, dt: 0.1)
        return system
    }

    func testBoidsAlignAndCohereWithSelfCountedAndGEqualOne() {
        // Each sees both: v̄ = (0,1,0), p̄ = (0.5,0,0); Δv = (v̄ − v)·1 + (p̄ − p)·2, times G·dt = 0.1.
        let system = boidsPair(maxCount: 2, frame: 0)
        assertEqual(system.velocity[0], SIMD3(0.1, 0.1, 0))
        assertEqual(system.velocity[1], SIMD3(-0.1, 1.9, 0))
    }

    func testBoidsSplitBlocksAcrossFramesWhenGIsTwo() {
        // 200 slots: G = 2, so block 0 (slots 0–3) runs on even frames with 2·dt and sits out odd ones.
        let even = boidsPair(maxCount: 200, frame: 0)
        assertEqual(even.velocity[0], SIMD3(0.2, 0.2, 0))
        assertEqual(even.velocity[1], SIMD3(-0.2, 1.8, 0))
        let odd = boidsPair(maxCount: 200, frame: 1)
        XCTAssertEqual(odd.velocity[0], .zero)
        XCTAssertEqual(odd.velocity[1], SIMD3(0, 2, 0))
    }

    func testBoidsCapsSpeedWhenItGrowsPastMaxSpeed() {
        let field = WPEParityParticleBoids(
            entry(#"{"separationthreshold": 0.5, "neighborthreshold": 2, "maxspeed": 0.05}"#), is3D: true
        )
        var system = particles(count: 2)
        place(&system, 0, at: .zero)
        place(&system, 1, at: SIMD3(1, 0, 0), velocity: SIMD3(0, 2, 0))
        system.applyBoids(field, blend: nil, dt: 0.1)
        XCTAssertEqual(simd_length(system.velocity[0]), 0.05, accuracy: 1e-6)
        // |v + Δv| = |(-0.1, 1.9, 0)| < |v| = 2: left alone.
        assertEqual(system.velocity[1], SIMD3(-0.1, 1.9, 0))
    }

    func testReduceMovementEqualReductionsUseADeltaOfOne() {
        func reduced(_ inner: Float, _ outer: Float) -> Float {
            var system = particles(extra: #", "operator": [{"name": "reducemovementnearcontrolpoint", "distanceinner": 1, "distanceouter": 3, "reductioninner": \#(inner), "reductionouter": \#(outer)}]"#)
            guard case let .reduceMovement(point, low, high, reductionInner, delta) = system.config.operators[0].kind else {
                XCTFail("operator not parsed")
                return 0
            }
            place(&system, 0, at: SIMD3(2, 0, 0), velocity: SIMD3(1, 0, 0))
            system.applyReduceMovement(
                controlPoint: point, inner: low, outer: high, reductionInner: reductionInner, reductionDelta: delta,
                slot: 0, weight: 1, dt: 0.1
            )
            return system.velocity[0].x
        }
        // s = 0.5: (5 + 0.5·(1 − 5))·0.1 = 0.3.
        XCTAssertEqual(reduced(5, 1), 0.7, accuracy: 1e-6)
        // rin == rout == 3: Δr is 1, so (3 + 0.5)·0.1 = 0.35 rather than 0.3.
        XCTAssertEqual(reduced(3, 3), 0.65, accuracy: 1e-6)
    }

    func testMaintainDistanceFollowsThePointAndPullsToTheDistance() {
        var system = particles()
        system.controlPoints[0] = System.translation(SIMD3(1, 0, 0))
        system.previousControlPoints[0] = matrix_identity_float4x4
        place(&system, 0, at: SIMD3(0, 3, 0))
        system.applyMaintainDistance(controlPoint: 0, distance: 2, variableStrength: 0, slot: 0, weight: 1, dt: 0.1)
        // q = (1,3,0), e = (0,3,0): q + (2/3 − 1)·e.
        assertEqual(system.position[0], SIMD3(1, 2, 0))
        place(&system, 0, at: SIMD3(0, 3, 0))
        system.applyMaintainDistance(controlPoint: 0, distance: 2, variableStrength: 5, slot: 0, weight: 1, dt: 0.1)
        assertEqual(system.position[0], SIMD3(1, 2.5, 0))
    }

    func testMaintainDistanceBetweenCarriesThePlaceAlongTheSegment() {
        var system = particles(controlPoint: 1)
        system.previousControlPoints[0] = matrix_identity_float4x4
        system.previousControlPoints[1] = System.translation(SIMD3(2, 0, 0))
        system.controlPoints[0] = System.translation(SIMD3(0, 1, 0))
        system.controlPoints[1] = System.translation(SIMD3(0, 1, 4))
        place(&system, 0, at: SIMD3(1, 0.5, 0))
        system.applyMaintainBetween(start: 0, end: 1, slot: 0, weight: 1)
        // Halfway along A0→B0 with perpendicular (0,0.5,0): A + 0.5·(B − A) + (0,0.5,0).
        assertEqual(system.position[0], SIMD3(0, 1.5, 2))
    }

    func testCollisionPlaneBouncesBelowThePlaneOnly() {
        let field = WPEParityParticleCollision(entry("{}"), sphere: false, is3D: true)
        var system = particles()
        place(&system, 0, at: SIMD3(1, -0.2, 0), velocity: SIMD3(2, -3, 0))
        system.applyCollisionPlane(field, slot: 0, weight: 1)
        // p −= (s − d)·n; v += −(1 + 0.5)(v·n)n.
        assertEqual(system.position[0], SIMD3(1, 0, 0))
        assertEqual(system.velocity[0], SIMD3(2, 1.5, 0))
        place(&system, 0, at: SIMD3(1, 0.2, 0), velocity: SIMD3(2, -3, 0))
        system.applyCollisionPlane(field, slot: 0, weight: 1)
        XCTAssertEqual(system.position[0], SIMD3(1, 0.2, 0))
        XCTAssertEqual(system.velocity[0], SIMD3(2, -3, 0))
    }

    func testTurbulenceRotatesTheNoiseArgumentsPerAxisAndSkipsMaskedAxes() {
        let field = WPEParityParticleTurbulence(entry(#"{"mask": "1 0 1"}"#), is3D: true)
        var system = particles()
        place(&system, 0, at: SIMD3(0.3, -0.4, 0.8))
        system.frameContext.time = 2
        system.applyTurbulence(field, slot: 0, weight: 1, dt: 0.1)
        // φ = T·timescale (phase range 0); speed = 1 + u·4; point = (p + φ)·0.5.
        let speed = 1 + system.birthU[0] * 4
        let point = (SIMD3<Float>(0.3, -0.4, 0.8) + 2) * 0.5
        let x = 0.1 * speed * WPEParityParticleNoise.simplex3(point.x, point.y, point.z)
        let z = 0.1 * speed * WPEParityParticleNoise.simplex3(point.y, point.z, point.x)
        assertEqual(system.velocity[0], SIMD3(x, 0, z))
        XCTAssertNotEqual(x, 0)
    }

    func testCursorControlPointUnprojectsThroughViewProjectionAndObject() {
        let cp = #", "controlpoint": [{"id": 0, "flags": 1}, {"id": 1, "offset": "1 2 3"}, {"id": 2, "offset": "1 2 3", "flags": 2}]"#
        let object = System.translation(SIMD3(10, 0, 0))
        for world in [false, true] {
            // 1c5490's resolved emitter CP2 reference allocates CP0...2; authored declarations alone do not.
            var system = particles(extra: cp, flags: world ? 1 : 0, controlPoint: 2)
            XCTAssertEqual(system.controlPointCount, 3)
            system.advance(dt: 0.01, frame: .init(cursor: SIMD2(0.5, 0.5)))
            assertEqual(system.controlPointTranslation(0), .zero)
            system.advance(dt: 0.01, frame: .init(cursor: SIMD2(0.75, 0.25), objectMatrix: object))
            // 22e3e0: NDC(.5,.5) is world-plane z0, then only local nodes apply inverse(U).
            let cursor = SIMD3<Float>(world ? 0.5 : -9.5, 0.5, 0)
            assertEqual(system.controlPointTranslation(0), cursor)
            assertEqual(system.previousControlPointTranslation(0), cursor)
            assertEqual(system.controlPointTranslation(1), SIMD3(world ? 11 : 1, 2, 3))
            // 22a070: local flags2 uses inverse(U)*A; world nonzero index keeps authored current.
            assertEqual(system.controlPointTranslation(2), SIMD3(world ? 1 : -9, 2, 3))
            system.advance(dt: 0.01, frame: .init(objectMatrix: object))
            // Mac nil-cursor policy retains the last point.
            assertEqual(system.controlPointTranslation(0), cursor)
        }
    }

    func testCursorUsesTheWorldPlaneBeforeRotatedObjectConversionAndAttract() {
        let projection = WPEParityCamera.ortho(left: 0, right: 100, bottom: 0, top: 100, near: -2000, far: 2000)
        let unprojected = projection.inverse * SIMD4<Float>(0.5, 0.5, 0, 1)
        XCTAssertEqual(unprojected.z, -2000, accuracy: Float(2000).ulp * 4,
                       "The test must expose the real ortho near plane within Float inverse rounding")
        let object = simd_float4x4(columns: (
            SIMD4(1, 0, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(0, -1, 0, 0), SIMD4(10, 20, 30, 1)
        ))
        let cp = #", "controlpoint": [{"id": 0, "flags": 1}]"#
        let frame = WPEParityParticleFrameContext(cursor: SIMD2(0.75, 0.25), viewProjection: projection,
                                                  objectMatrix: object)
        var world = particles(extra: cp, flags: 1)
        world.advance(dt: 0.01, frame: frame)
        assertEqual(world.controlPointTranslation(0), SIMD3(75, 75, 0))
        let attract = WPEParityParticleAttract(entry(#"{"scale": 10, "threshold": 4, "flags": 0}"#), is3D: true)
        place(&world, 0, at: SIMD3(77, 75, 0))
        world.applyAttract(attract, slot: 0, weight: 1, dt: 0.1)
        assertEqual(world.velocity[0], SIMD3(-0.5, 0, 0))
        var local = particles(extra: cp)
        local.advance(dt: 0.01, frame: frame)
        // inverse(U)*(75,75,0,1), with a 90° X rotation and nonzero object depth.
        assertEqual(local.controlPointTranslation(0), SIMD3(65, -30, -55))
    }

    func testControlPointHistoryKeepsTheFullPreviousTransformUntilOperatorsFinish() {
        var system = System(json: Support.json("""
        {"maxcount": 1, "flags": 1,
         "emitter": [{"name": "sphererandom", "rate": 0, "instantaneous": 1, "origin": "0 3 0", "distancemax": 0}],
         "initializer": [{"name": "lifetimerandom", "min": 100, "max": 100}],
         "operator": [{"name": "maintaindistancetocontrolpoint", "distance": 2}]}
        """), rng: WPEParityMT19937())
        system.advance(dt: 0.001)
        place(&system, 0, at: SIMD3(0, 3, 0))
        let first = simd_float4x4(columns: (
            SIMD4(1, 0, 0, 0), SIMD4(0, 2, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(1, 0, 0, 1)
        ))
        system.advance(dt: 0.1, frame: .init(objectMatrix: first))
        // Carry by the CP delta first, then measure distance in the current scaled CP basis.
        assertEqual(system.position[0], SIMD3(1, 4, 0))
        XCTAssertTrue(simd_almost_equal_elements(system.previousControlPoints[0], first, 1e-6))
        let second = simd_float4x4(columns: (
            SIMD4(2, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(2, 0, 0, 1)
        ))
        system.advance(dt: 0.1, frame: .init(objectMatrix: second))
        assertEqual(system.position[0], SIMD3(2, 2, 0))
        XCTAssertTrue(simd_almost_equal_elements(system.previousControlPoints[0], second, 1e-6))
    }

    func testParentCopyUsesResolvedParentCountAndFallsBackToTheAuthoredPoint() {
        let child = Support.json("""
        {"maxcount": 1,
         "emitter": [{"name": "sphererandom", "rate": 0, "controlpoint": 0}],
         "controlpoint": [{"id": 0, "flags": 4, "parentcontrolpoint": 1, "offset": "7 8 9"}]}
        """)
        for referenced in [false, true] {
            // 1c5490 raises count for component references, not for authored CP1's presence.
            let emitter = referenced ? #", "emitter": [{"name": "sphererandom", "rate": 0, "controlpoint": 1}]"# : ""
            var system = System(json: Support.json("""
            {"maxcount": 1, "controlpoint": [{"id": 1, "offset": "4 5 6"}],
             "children": [{"name": "child.json", "type": "static"}]\(emitter)}
            """), rng: WPEParityMT19937(), resolveChild: { _ in child })
            XCTAssertEqual(system.controlPointCount, referenced ? 2 : 0)
            XCTAssertEqual(system.children[0].controlPointCount, 1)
            system.advance(dt: 0.01)
            // 22e3e0 invalid-parent path invokes ordinary; local ordinary retains authored current.
            assertEqual(system.children[0].controlPointTranslation(0), referenced ? SIMD3(4, 5, 6) : SIMD3(7, 8, 9))
        }
    }
}
