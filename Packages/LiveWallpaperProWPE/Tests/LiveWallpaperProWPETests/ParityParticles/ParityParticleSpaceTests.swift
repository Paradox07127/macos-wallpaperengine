@testable import LiveWallpaperProWPE
import simd
import XCTest

/// Expected E/U/CP/SoA/D values are hand-derived from 22a360/229760/229810/22e3e0/2366f0.
/// These guards do not use the product's transform helpers to calculate their expected values.
final class ParityParticleSpaceTests: XCTestCase {
    private func translation(_ x: Float, _ y: Float = 0, _ z: Float = 0) -> simd_float4x4 {
        simd_float4x4(SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(x, y, z, 1))
    }

    private func emitter(fixedPositiveX: Bool = false, point: Int = 0, origin: String = "1 0 0", rate: Float = 10,
                         speed: Float = 0, instantaneous: Int = 0, duration: Float = 0) -> String {
        """
        {"name":"\(fixedPositiveX ? "sphererandom" : "boxrandom")","cone":1,"controlpoint":\(point),"origin":"\(origin)","rate":\(rate),
         "instantaneous":\(instantaneous),"duration":\(duration),"directions":"1 1 1","distancemin":"1 0 0",
         "distancemax":"1 0 0","speedmin":\(speed),"speedmax":\(speed)}
        """
    }

    private func system(_ json: String, owner: simd_float4x4 = matrix_identity_float4x4,
                        assets: [String: String] = [:], seed: UInt32 = 7) -> WPEParityParticleSystem {
        let config = WPEParityParticleConfig(json: ParityParticleTestSupport.json(json), is3D: true,
                                             resolveChild: { assets[$0].map(ParityParticleTestSupport.json) })
        return WPEParityParticleSystem(config: config, instance: .init(), rng: WPEParityMT19937(seed: seed),
                                       crt: WPEParityCRTRandom(), context: .init(objectMatrix: owner))
    }

    private func assertVector(_ actual: SIMD3<Float>, _ expected: SIMD3<Float>, _ message: String = "",
                              file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertLessThanOrEqual(simd_reduce_max(abs(actual - expected)), 0.0001, message, file: file, line: line)
    }

    private func x(_ matrix: simd_float4x4) -> Float {
        matrix.columns.3.x
    }

    func testEventFourSpacesKeepEUpdateCPAndRawBirthDistinctDespiteTheSameFinalPoint() throws {
        for parentWorld in [false, true] {
            for childWorld in [false, true] {
                let childJSON = """
                {"flags":\(childWorld ? 1 : 0),"maxcount":1,"starttime":0.05,
                 "emitter":[\(emitter(fixedPositiveX: true, rate: 20))],"initializer":[{"name":"lifetimerandom","min":10,"max":10}]}
                """
                var parent = system("""
                {"flags":\(parentWorld ? 1 : 0),"maxcount":1,"emitter":[\(emitter(fixedPositiveX: true, origin: "9 0 0"))],
                 "initializer":[{"name":"lifetimerandom","min":10,"max":10}],
                 "children":[{"name":"child","type":"eventspawn","origin":"3 0 0"}]}
                """, owner: translation(100), assets: ["child": childJSON])
                XCTAssertTrue(parent.config.unsupportedChildren.isEmpty)
                parent.advance(dt: 0.1, frame: .init(objectMatrix: translation(100)))
                let instance = try XCTUnwrap(parent.eventChildren.first?.first)
                XCTAssertEqual(parent.position[0].x, parentWorld ? 110 : 10)
                XCTAssertEqual(x(instance.instanceTransform), childWorld ? 113 : 13)
                XCTAssertEqual(x(instance.frameContext.objectMatrix), 113)
                XCTAssertEqual(x(instance.controlPoints[0]), childWorld ? 113 : 0)
                XCTAssertEqual(instance.position[0].x, childWorld ? 115 : 2)
                let stream = parent.drawStream(objectID: "p", ownerModel: translation(100),
                                               worldModel: matrix_identity_float4x4, needsFullFrameBuffer: { _ in false })
                let batch = try XCTUnwrap(stream.batches.last)
                XCTAssertEqual(batch.key.path, [.eventGroup(0)])
                XCTAssertEqual(x(batch.modelMatrix), childWorld ? 0 : 113)
                XCTAssertEqual((batch.modelMatrix * SIMD4(instance.position[0], 1)).x, 115)
                parent.advance(dt: 0.1, frame: .init(objectMatrix: translation(200)))
                let fixed = try XCTUnwrap(parent.eventChildren.first?.first)
                XCTAssertEqual(x(fixed.instanceTransform), childWorld ? 113 : 13, "Spawn E is fixed after creation")
                XCTAssertEqual(fixed.position[0].x, childWorld ? 115 : 2)
                let moved = parent.drawStream(objectID: "p", ownerModel: translation(200),
                                              worldModel: matrix_identity_float4x4, needsFullFrameBuffer: { _ in false })
                let movedBatch = try XCTUnwrap(moved.batches.last)
                XCTAssertEqual((movedBatch.modelMatrix * SIMD4(fixed.position[0], 1)).x, childWorld ? 115 : 215)
            }
        }
    }

    func testDeathFourSpacesUseTheCurrentParentUpdateStackBeforeRebirth() throws {
        for parentWorld in [false, true] {
            for childWorld in [false, true] {
                let childJSON = """
                {"flags":\(childWorld ? 1 : 0),"maxcount":1,"starttime":0.05,
                 "emitter":[\(emitter(fixedPositiveX: true, rate: 20))],"initializer":[{"name":"lifetimerandom","min":10,"max":10}]}
                """
                var parent = system("""
                {"flags":\(parentWorld ? 1 : 0),"maxcount":1,"emitter":[\(emitter(fixedPositiveX: true, origin: "9 0 0"))],
                 "initializer":[{"name":"lifetimerandom","min":0.05,"max":0.05}],
                 "children":[{"name":"child","type":"eventdeath","origin":"3 0 0"}]}
                """, owner: translation(100), assets: ["child": childJSON])
                parent.advance(dt: 0.1, frame: .init(objectMatrix: translation(100)))
                XCTAssertTrue(parent.eventChildren[0].isEmpty)
                parent.advance(dt: 0.1, frame: .init(objectMatrix: translation(200)))
                let child = try XCTUnwrap(parent.eventChildren.first?.first)
                let modelX: Float = parentWorld ? 113 : 213
                XCTAssertEqual(x(child.instanceTransform), childWorld ? modelX : (parentWorld ? -87 : 13))
                XCTAssertEqual(child.position[0].x, childWorld ? modelX + 2 : 2)
                let stream = parent.drawStream(objectID: "p", ownerModel: translation(200),
                                               worldModel: matrix_identity_float4x4, needsFullFrameBuffer: { _ in false })
                let batch = try XCTUnwrap(stream.batches.last)
                XCTAssertEqual((batch.modelMatrix * SIMD4(child.position[0], 1)).x, modelX + 2)
                let expected = WPEParityMT19937(seed: 7)
                for _ in 0 ..< 19 {
                    _ = expected.next()
                } // Parent6, death probability1, child6, reborn parent6.
                XCTAssertEqual(parent.rng.next(), expected.next())
            }
        }
    }

    func testFollowRefreshesEAfterMovementWithoutMovingExistingWorldSoAAndDetachKeepsLastE() throws {
        for parentWorld in [false, true] {
            for childWorld in [false, true] {
                let childJSON = """
                {"flags":\(childWorld ? 1 : 0),"maxcount":1,"starttime":0.05,
                 "emitter":[\(emitter(fixedPositiveX: true, rate: 20))],"initializer":[{"name":"lifetimerandom","min":10,"max":10}]}
                """
                var parent = system("""
                {"flags":\(parentWorld ? 1 : 0),"maxcount":1,"emitter":[\(emitter(fixedPositiveX: true, origin: "9 0 0", speed: 1, duration: 0.01))],
                 "initializer":[{"name":"lifetimerandom","min":0.15,"max":0.15}],
                 "operator":[{"name":"movement"}],
                 "children":[{"name":"child","type":"eventfollow","origin":"3 0 0"}]}
                """, owner: translation(100), assets: ["child": childJSON])
                parent.advance(dt: 0.1, frame: .init(objectMatrix: translation(100)))
                let first = try XCTUnwrap(parent.eventChildren.first?.first)
                XCTAssertEqual(x(first.instanceTransform), childWorld ? 113.1 : 13.1, accuracy: 0.0001)
                XCTAssertEqual(first.position[0].x, childWorld ? 115 : 2, accuracy: 0.0001)
                parent.advance(dt: 0.1, frame: .init(objectMatrix: translation(200)))
                let next = try XCTUnwrap(parent.eventChildren.first?.first)
                let updateX: Float = parentWorld ? 113.2 : 213.2
                let placementX: Float = childWorld ? updateX : (parentWorld ? -86.8 : 13.2)
                XCTAssertEqual(x(next.instanceTransform), placementX, accuracy: 0.0001)
                XCTAssertEqual(x(next.frameContext.objectMatrix), updateX, accuracy: 0.0001)
                XCTAssertEqual(next.position[0].x, childWorld ? 115 : 2, accuracy: 0.0001)
                let stream = parent.drawStream(objectID: "p", ownerModel: translation(200),
                                               worldModel: matrix_identity_float4x4, needsFullFrameBuffer: { _ in false })
                let batch = try XCTUnwrap(stream.batches.last)
                XCTAssertEqual((batch.modelMatrix * SIMD4(next.position[0], 1)).x,
                               childWorld ? 115 : updateX + 2, accuracy: 0.0001)
                parent.advance(dt: 0.1, frame: .init(objectMatrix: translation(300)))
                let detached = try XCTUnwrap(parent.eventChildren.first?.first)
                XCTAssertEqual(detached.parentSlot, -1)
                XCTAssertEqual(x(detached.instanceTransform), placementX, accuracy: 0.0001)
                XCTAssertNil(detached.parentSample)
                XCTAssertTrue(detached.emitterStates.allSatisfy(\.disabled))
                XCTAssertEqual(detached.liveCount, 1)
            }
        }
    }

    func testWorldBirthTransformsShapeBeforeSpeedButNeverRotatesEmitterOrigin() {
        let model = simd_float4x4(SIMD4(0, 2, 0, 0), SIMD4(-1, 0, 0, 0),
                                  SIMD4(0, 0, 1, 0), SIMD4(100, 0, 0, 1))
        var value = system("""
        {"flags":1,"maxcount":1,"emitter":[\(emitter(origin: "3 4 0", speed: 2))],
         "initializer":[{"name":"lifetimerandom","min":10,"max":10}]}
        """, owner: model)
        value.advance(dt: 0.1, frame: .init(objectMatrix: model))
        assertVector(value.position[0], SIMD3(103, 6, 0))
        assertVector(value.velocity[0], SIMD3(0, 2, 0))
        XCTAssertEqual(simd_length(value.velocity[0]), 2, accuracy: 0.0001)
        let expected = WPEParityMT19937(seed: 7)
        for _ in 0 ..< 6 {
            _ = expected.next()
        } // box xyz, speed, birthU, lifetime; transforms consume no words.
        XCTAssertEqual(value.rng.next(), expected.next())
    }

    func testWorldEventChildConsumesRadiansAndNonuniformScaleWithoutBakingLocalParticles() throws {
        for childWorld in [false, true] {
            let childJSON = """
            {"flags":\(childWorld ? 1 : 0),"maxcount":1,"starttime":0.05,"emitter":[\(emitter(rate: 20))]}
            """
            var parent = system("""
            {"flags":1,"maxcount":1,"emitter":[\(emitter(origin: "9 0 0"))],
             "children":[{"name":"child","type":"eventspawn","origin":"3 0 0",
                          "angles":"0 0 1.5707963267948966","scale":"2 1 1"}]}
            """, owner: translation(100), assets: ["child": childJSON])
            parent.advance(dt: 0.1, frame: .init(objectMatrix: translation(100)))
            let child = try XCTUnwrap(parent.eventChildren.first?.first)
            XCTAssertEqual(child.instanceTransform.columns.0.y, 2, accuracy: 0.0001)
            XCTAssertEqual(child.instanceTransform.columns.1.x, -1, accuracy: 0.0001)
            let stream = parent.drawStream(objectID: "p", ownerModel: translation(100),
                                           worldModel: matrix_identity_float4x4, needsFullFrameBuffer: { _ in false })
            let batch = try XCTUnwrap(stream.batches.last)
            let point = batch.modelMatrix * SIMD4(child.position[0], 1)
            assertVector(SIMD3(point.x, point.y, point.z), childWorld ? SIMD3(114, 2, 0) : SIMD3(113, 4, 0))
            if !childWorld {
                assertVector(child.position[0], SIMD3(2, 0, 0))
            }
        }
    }

    func testWorldStaticFreshConditionalPushAndNormalStaticPushProduceDifferentBirths() {
        let childJSON = """
        {"flags":1,"maxcount":3,"starttime":0.05,"emitter":[\(emitter(rate: 20))],
         "initializer":[{"name":"lifetimerandom","min":10,"max":10}]}
        """
        var parent = system("""
        {"maxcount":0,"renderer":[],"children":[{"name":"child","origin":"5 0 0"}]}
        """, owner: translation(100), assets: ["child": childJSON])
        XCTAssertEqual(x(parent.children[0].instanceTransform), 5)
        XCTAssertEqual(x(parent.children[0].frameContext.objectMatrix), 5)
        XCTAssertEqual(parent.children[0].position[0].x, 7)
        parent.advance(dt: 0.05, frame: .init(objectMatrix: translation(100)))
        XCTAssertEqual(x(parent.children[0].instanceTransform), 5)
        XCTAssertEqual(x(parent.children[0].frameContext.objectMatrix), 105)
        XCTAssertEqual(parent.children[0].liveCount, 2)
        XCTAssertEqual(Array(parent.children[0].position.prefix(2)), [SIMD3(7, 0, 0), SIMD3(107, 0, 0)])
    }

    func testCompositeWorldParentResetsItsDescendantDrawStackEvenWithoutAnOwnDraw() throws {
        let childJSON = """
        {"maxcount":1,"starttime":0.05,"emitter":[\(emitter(rate: 20))]}
        """
        var parent = system("""
        {"flags":1,"maxcount":0,"renderer":[],"children":[{"name":"child","origin":"5 0 0"}]}
        """, owner: translation(100), assets: ["child": childJSON])
        let stream = parent.drawStream(objectID: "p", ownerModel: translation(100), worldModel: translation(-50),
                                       needsFullFrameBuffer: { _ in false })
        XCTAssertEqual(parent.liveCount, 0)
        XCTAssertEqual(stream.batches.count, 1)
        let batch = try XCTUnwrap(stream.batches.first)
        XCTAssertEqual(x(batch.modelMatrix), 105)
        XCTAssertEqual((batch.modelMatrix * SIMD4(parent.children[0].position[0], 1)).x, 107)
        var visited: [[WPEParityParticlePathElement]] = []
        let pruned = parent.drawStream(objectID: "p", ownerModel: translation(100), worldModel: translation(-50),
                                       needsFullFrameBuffer: { path in visited.append(path); return nil })
        XCTAssertTrue(pruned.batches.isEmpty)
        XCTAssertEqual(visited, [[]], "An unavailable base material prunes descendants before their probes/draws")
    }

    func testParentCopyUsesParentAndCurrentUpdateSpacesAndTheNativeDirectCopyBit() {
        for parentWorld in [false, true] {
            for childWorld in [false, true] {
                for direct in [false, true] {
                    let config = WPEParityParticleConfig(json: ParityParticleTestSupport.json("""
                    {"flags":\(childWorld ? 1 : 0),"maxcount":1,"starttime":0.05,"emitter":[\(emitter(rate: 20))],
                     "controlpoint":[{"offset":"9 0 0","flags":\(direct ? 12 : 4)}]}
                    """), is3D: true, resolveChild: { _ in nil })
                    let value = WPEParityParticleSystem(
                        config: config, instance: .init(), rng: WPEParityMT19937(seed: 7), crt: WPEParityCRTRandom(),
                        instanceTransform: translation(3), parentControlPoints: [translation(parentWorld ? 110 : 10)],
                        parentControlPointCount: 1, parentUpdateMatrix: translation(100), parentWorldSpace: parentWorld
                    )
                    let expected: Float = direct ? (parentWorld ? 110 : 10) : (childWorld ? 110 : 7)
                    XCTAssertEqual(x(value.controlPoints[0]), expected)
                    XCTAssertEqual(value.position[0].x, expected + 2)
                    XCTAssertEqual(x(value.previousControlPoints[0]), expected, "Fresh history is seeded after CP update")
                }
            }
        }
    }

    func testEffectiveControlPointCountRejectsAnUnallocatedParentPointAndBulkAloneForcesEight() {
        let config = WPEParityParticleConfig(json: ParityParticleTestSupport.json("""
        {"flags":1,"maxcount":1,"emitter":[\(emitter())],
         "controlpoint":[{"offset":"9 0 0","flags":4,"parentcontrolpoint":7},
                         {"id":7,"offset":"999 0 0"}]}
        """), is3D: true, resolveChild: { _ in nil })
        XCTAssertEqual(config.controlPointCount, 1, "Authored CP declarations do not allocate unreferenced runtime points")
        var parentPoints = Array(repeating: matrix_identity_float4x4, count: 8)
        parentPoints[7] = translation(999)
        let missing = WPEParityParticleSystem(
            config: config, instance: .init(), rng: WPEParityMT19937(seed: 7), crt: WPEParityCRTRandom(),
            instanceTransform: translation(3), parentControlPoints: parentPoints,
            parentControlPointCount: 1, parentUpdateMatrix: translation(100)
        )
        XCTAssertEqual(x(missing.controlPoints[0]), 12, "Invalid parent CP falls back to ordinary U*A, not CP7")
        let bulk = WPEParityParticleSystem(config: config, instance: .init(), rng: WPEParityMT19937(seed: 7),
                                           crt: WPEParityCRTRandom(), bulkControlPointStart: 6)
        XCTAssertEqual(bulk.controlPointCount, 8)
        for rawIndex in [-1, 8] {
            let invalidConfig = WPEParityParticleConfig(json: ParityParticleTestSupport.json("""
            {"flags":1,"maxcount":1,"emitter":[\(emitter())],
             "controlpoint":[{"offset":"9 0 0","flags":4,"parentcontrolpoint":\(rawIndex)}]}
            """), is3D: true, resolveChild: { _ in nil })
            let invalid = WPEParityParticleSystem(
                config: invalidConfig, instance: .init(), rng: WPEParityMT19937(seed: 7), crt: WPEParityCRTRandom(),
                instanceTransform: translation(3), parentControlPoints: parentPoints,
                parentControlPointCount: 8, parentUpdateMatrix: translation(100)
            )
            XCTAssertEqual(x(invalid.controlPoints[0]), 12, "Raw parent index must not clamp to CP7")
        }
    }

    func testFrozenAuthoredPointAndWorldFlagsTwoIndexZeroReachActualBirths() {
        var frozen = system("""
        {"flags":1,"maxcount":1,"emitter":[\(emitter())],
         "controlpoint":[{"offset":"9 0 0","flags":65536}]}
        """, owner: translation(100))
        frozen.advance(dt: 0.1, frame: .init(objectMatrix: translation(100)))
        XCTAssertEqual(x(frozen.controlPoints[0]), 9)
        XCTAssertEqual(frozen.position[0].x, 11)
        for point in [0, 1] {
            var value = system("""
            {"flags":1,"maxcount":1,"emitter":[\(emitter(point: point))],
             "controlpoint":[{"offset":"9 0 0","flags":2},{"offset":"9 0 0","flags":2}]}
            """, owner: translation(100))
            value.advance(dt: 0.1, frame: .init(objectMatrix: translation(100)))
            XCTAssertEqual(value.position[0].x, point == 0 ? 111 : 11)
        }
    }

    func testCursorPreservesNativeBaseBasisAndUnprojectsZBeforeLocalConversion() {
        var value = system("""
        {"maxcount":1,"emitter":[\(emitter(point: 1, origin: "0 0 0", speed: 2))],
         "controlpoint":[{}, {"offset":"9 0 0","flags":1}]}
        """)
        // Inject the native CP+0x80 input boundary; this does not claim an authored special-CP angle producer.
        value.controlPointBases[1] = simd_float4x4(SIMD4(2, 0, 0, 0), SIMD4(0, 3, 0, 0),
                                                   SIMD4(0, 0, 4, 0), SIMD4(9, 0, 0, 1))
        value.advance(dt: 0.1, frame: .init(cursor: SIMD2(0.75, 0.25), objectMatrix: translation(2, 3, 4)))
        assertVector(value.position[0], SIMD3(0.5, -2.5, -4))
        assertVector(value.velocity[0], SIMD3(2, 0, 0))
        XCTAssertEqual(value.controlPoints[1].columns.1.y, 3)
        XCTAssertEqual(value.controlPoints[1].columns.2.z, 4)
    }

    func testBulkControlPointsUseLiveRawSlotOrderAndAllFourSpaceMappings() {
        for parentWorld in [false, true] {
            for childWorld in [false, true] {
                let childJSON = """
                {"flags":\(childWorld ? 1 : 0),"maxcount":1,"emitter":[\(emitter(point: 7))]}
                """
                var parent = system("""
                {"flags":\(parentWorld ? 1 : 0),"maxcount":3,"renderer":[],
                 "children":[{"name":"child","flags":1,"controlpointstartindex":6,"origin":"3 0 0"}]}
                """, owner: translation(100), assets: ["child": childJSON])
                while parent.lifetime.count < 3 {
                    parent.growSlots()
                }
                parent.highWater = 3
                parent.liveCount = 2
                parent.lifetime[0] = 10
                parent.lifetime[2] = 10
                parent.position[0] = SIMD3(parentWorld ? 102 : 2, 0, 0)
                parent.position[2] = SIMD3(parentWorld ? 107 : 7, 0, 0)
                parent.children[0].controlPoints[6].columns.0.x = 2
                parent.advance(dt: 0.1, frame: .init(objectMatrix: translation(100)))
                let child = parent.children[0]
                XCTAssertEqual(child.controlPointCount, 8)
                XCTAssertEqual(x(child.controlPoints[6]), childWorld ? 102 : 2)
                XCTAssertEqual(x(child.controlPoints[7]), childWorld ? 107 : 7)
                XCTAssertEqual(child.controlPoints[6].columns.0.x, 2)
                XCTAssertEqual(child.position[0].x, childWorld ? 109 : 9)
                XCTAssertEqual(x(child.previousControlPoints[7]), childWorld ? 107 : 7)
            }
        }
    }

    func testBulkSpecialTargetDoesNotAdvanceToTheNextPoint() {
        let childJSON = """
        {"maxcount":1,"emitter":[\(emitter(point: 7))],
         "controlpoint":[{"id":6,"offset":"60 0 0","flags":1},{"id":7,"offset":"70 0 0"}]}
        """
        var parent = system("""
        {"maxcount":2,"renderer":[],"children":[{"name":"child","flags":1,"controlpointstartindex":6}]}
        """, assets: ["child": childJSON])
        while parent.lifetime.count < 2 {
            parent.growSlots()
        }
        parent.highWater = 2
        parent.liveCount = 2
        parent.lifetime[0] = 10
        parent.lifetime[1] = 10
        parent.position[0] = SIMD3(2, 0, 0)
        parent.position[1] = SIMD3(7, 0, 0)
        parent.advance(dt: 0.1)
        XCTAssertEqual(x(parent.children[0].controlPoints[6]), 60)
        XCTAssertEqual(x(parent.children[0].controlPoints[7]), 70)
        XCTAssertEqual(parent.children[0].position[0].x, 72)
    }

    func testWorldFinishedReuseRetainsHistoryUntilThePrewarmOperatorCommitsIt() throws {
        let childJSON = """
        {"flags":1,"maxcount":1,"starttime":0.05,"emitter":[\(emitter(fixedPositiveX: true, rate: 0, instantaneous: 1))],
         "initializer":[{"name":"lifetimerandom","min":0.05,"max":0.05}],
         "operator":[{"name":"maintaindistancetocontrolpoint","distance":2,"variablestrength":10}]}
        """
        var parent = system("""
        {"maxcount":4,"emitter":[\(emitter(fixedPositiveX: true, origin: "9 0 0"))],
         "initializer":[{"name":"lifetimerandom","min":10,"max":10}],
         "children":[{"name":"child","type":"eventspawn","origin":"3 0 0","maxcount":1}]}
        """, owner: translation(100), assets: ["child": childJSON])
        parent.advance(dt: 0.1, frame: .init(objectMatrix: translation(100)))
        let first = try XCTUnwrap(parent.finishedEventChildren.first?.first)
        XCTAssertEqual(first.position[0].x, 115, accuracy: 0.0001)
        XCTAssertEqual(x(first.previousControlPoints[0]), 113)
        parent.advance(dt: 0.1, frame: .init(objectMatrix: translation(200)))
        let reused = try XCTUnwrap(parent.finishedEventChildren.first?.first)
        XCTAssertEqual(parent.eventChildConstructions, 1)
        // Cone1 spheres fix +X; phi/cosTheta/radius still consume three words, like the box fixtures.
        // Reuse keeps previous113. New CP213, birth215: q315; e102; k=.5 =>315+.5*(2-102)=265.
        XCTAssertEqual(reused.position[0].x, 265, accuracy: 0.0001)
        XCTAssertEqual(x(reused.previousControlPoints[0]), 213)
        let expected = WPEParityMT19937(seed: 7)
        for _ in 0 ..< 26 {
            _ = expected.next()
        } // Two times: parent6 + probability1 + reused child6.
        XCTAssertEqual(parent.rng.next(), expected.next())
    }

    func testHiddenResetKeepsWorldControlPointHistoryWithoutRepeatingConstructionPrewarm() {
        var value = system("""
        {"flags":1,"maxcount":1,"starttime":0.05,"emitter":[\(emitter(rate: 0, instantaneous: 1))],
         "initializer":[{"name":"lifetimerandom","min":10,"max":10}],
         "operator":[{"name":"maintaindistancetocontrolpoint","distance":2,"variablestrength":5}]}
        """, owner: translation(100))
        XCTAssertEqual(value.position[0].x, 102)
        value.reset()
        XCTAssertEqual(value.liveCount, 0)
        XCTAssertEqual(x(value.controlPoints[0]), 100)
        XCTAssertEqual(x(value.previousControlPoints[0]), 100)
        XCTAssertTrue(value.controlPointsSeeded)
        // The reset keeps the spent one-shot emitter disabled; play re-arms it without touching CP history.
        value.play()
        value.advance(dt: 0.1, frame: .init(objectMatrix: translation(200)))
        // q = birth202 + retained delta100 =302; e102; k=.5 =>252.
        XCTAssertEqual(value.position[0].x, 252, accuracy: 0.0001)
        XCTAssertEqual(value.prewarmStepCount, 0)
        XCTAssertEqual(x(value.previousControlPoints[0]), 200)
        let expected = WPEParityMT19937(seed: 7)
        for _ in 0 ..< 12 {
            _ = expected.next()
        }
        XCTAssertEqual(value.rng.next(), expected.next())
    }

    func testChildRemapLayerOriginReadsOwnerWorldRatherThanTheChildUpdateStack() {
        let childJSON = """
        {"maxcount":1,"emitter":[\(emitter())],
         "operator":[{"name":"remapvalue","input":"layerorigin","output":"position","operation":"remap"}]}
        """
        var parent = system("""
        {"maxcount":0,"renderer":[],"children":[{"name":"child","origin":"7 0 0"}]}
        """, owner: translation(100, 20), assets: ["child": childJSON])
        parent.advance(dt: 0.1, frame: .init(objectMatrix: translation(100, 20)))
        XCTAssertEqual(x(parent.children[0].frameContext.objectMatrix), 107)
        assertVector(parent.children[0].position[0], SIMD3(100, 20, 0))
    }
}
