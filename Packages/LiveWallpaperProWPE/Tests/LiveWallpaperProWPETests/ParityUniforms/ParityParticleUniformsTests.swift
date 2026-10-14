@testable import LiveWallpaperProWPE
import simd
import XCTest

final class ParityParticleUniformsTests: XCTestCase {
    private let canvas = SIMD2<Float>(1920, 1080)
    private let s = 1 / Float(2).squareRoot()

    private func assertEqual(_ lhs: simd_float4x4, _ rhs: simd_float4x4, accuracy: Float = 1e-4,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(simd_almost_equal_elements(lhs, rhs, accuracy), "\(lhs) != \(rhs)", file: file, line: line)
    }

    private func assertEqual(_ lhs: SIMD3<Float>, _ rhs: SIMD3<Float>, _ message: String = "",
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertLessThan(simd_distance(lhs, rhs), 1e-5, "\(message) \(lhs) != \(rhs)", file: file, line: line)
    }

    private func translation(_ x: Float, _ y: Float, _ z: Float = 0) -> simd_float4x4 {
        var matrix = matrix_identity_float4x4
        matrix.columns.3 = SIMD4(x, y, z, 1)
        return matrix
    }

    private func transforms(_ layers: [WPEParityLayerTransform], fov: Float = 50) -> WPEParityLayerTransformSet {
        let camera = WPEParityCamera(eye: .zero, center: SIMD3(0, 0, -1), up: SIMD3(0, 1, 0), size: canvas,
                                     renderTargetSize: canvas, perspectiveFOV: fov)
        return WPEParityLayerTransformSet(camera: camera, layers: layers)
    }

    private func renderer(_ json: String) throws -> WPEParityParticleRenderer {
        try XCTUnwrap(WPEParityParticleRenderer(name: "rope", json: ParityParticleTestSupport.json(json)))
    }

    // MARK: Layers

    func testDocumentLayersIncludeParticlesWithLocalTransform() throws {
        let document = try ParityCameraFixture.document(json: """
        {"camera": {"center": "0 0 0"}, "general": {"orthogonalprojection": {"width": 1920, "height": 1080}},
         "objects": [
          {"id": 1, "name": "group", "origin": "100 50 0"},
          {"id": 2, "name": "rain", "particle": "particles/rain.json", "parent": 1, "origin": "10 20 0",
           "parallaxDepth": "0.5 0.25"}
         ]}
        """)
        let particle = try XCTUnwrap(WPEParityLayerTransform.layers(document: document).first { $0.id == "2" })
        XCTAssertEqual(particle, WPEParityLayerTransform(id: "2", parentID: "1", origin: SIMD3(10, 20, 0),
                                                         parallaxDepth: SIMD2(0.5, 0.25)))
    }

    // MARK: Matrices

    func testDrawConsumesFinalParticleModelWithoutReapplyingTheOwnerChain() {
        let parent = WPEParityLayerTransform(id: "p", origin: SIMD3(100, 50, 0), size: SIMD2(400, 300),
                                             alignment: .left)
        let emitter = WPEParityLayerTransform(id: "e", parentID: "p", origin: SIMD3(10, 20, 0))
        let set = transforms([parent, emitter])
        // 236600/2366f0 already produced D: parent alignment does not reach its children.
        let matrices = WPEParityParticleMatrices.draw(set, objectID: "e", modelMatrix: translation(111, 72, 3),
                                                      perspective: false, compositeOwnerID: nil, parallax: canvas / 2)
        assertEqual(matrices.model, translation(111, 72, 3))
        assertEqual(matrices.view, matrix_identity_float4x4)
        let sceneProjection = simd_float4x4(SIMD4(1.0 / 960, 0, 0, 0), SIMD4(0, 1.0 / 540, 0, 0),
                                            SIMD4(0, 0, 0.00025, 0), SIMD4(-1, -1, 0.5, 1))
        assertEqual(matrices.projection, sceneProjection)
    }

    func testWorldSpaceParticleAtTopLevelUsesIdentityModel() {
        let emitter = WPEParityLayerTransform(id: "e", origin: SIMD3(10, 20, 0))
        let matrices = WPEParityParticleMatrices.draw(transforms([emitter]), objectID: "e",
                                                      modelMatrix: matrix_identity_float4x4, perspective: false,
                                                      compositeOwnerID: nil, parallax: canvas / 2)
        assertEqual(matrices.model, matrix_identity_float4x4)
    }

    func testWorldSpaceParticleInCompositeUsesInverseOwnerModel() {
        let owner = WPEParityLayerTransform(id: "p", origin: SIMD3(1000, 500, 0), angles: SIMD3(0, 0, .pi / 2),
                                            size: SIMD2(400, 300), alignment: .left)
        let emitter = WPEParityLayerTransform(id: "e", parentID: "p", origin: SIMD3(10, 20, 0))
        let set = transforms([owner, emitter])
        // C=inverse(T(1000,500)*Rz90*T(200,0)): the walker supplies this final world-node D once.
        let worldDraw = simd_float4x4(SIMD4(0, -1, 0, 0), SIMD4(1, 0, 0, 0),
                                      SIMD4(0, 0, 1, 0), SIMD4(-700, 1000, 0, 1))
        let matrices = WPEParityParticleMatrices.draw(set, objectID: "e", modelMatrix: worldDraw,
                                                      perspective: false, compositeOwnerID: "p", parallax: canvas / 2)
        assertEqual(matrices.model, worldDraw)
        assertEqual(matrices.view, matrix_identity_float4x4)
        let compositeProjection = simd_float4x4(SIMD4(0.005, 0, 0, 0), SIMD4(0, 1.0 / 150, 0, 0),
                                                SIMD4(0, 0, 0.0005, 0), SIMD4(0, 0, 0.5, 1))
        assertEqual(matrices.projection, compositeProjection)
        // Local D=C*Wemitter*T(1,2,3)=T(-200+10+1,20+2,3). Do not apply inverse(owner) again.
        let local = WPEParityParticleMatrices.draw(set, objectID: "e", modelMatrix: translation(-189, 22, 3),
                                                   perspective: false, compositeOwnerID: "p", parallax: canvas / 2)
        assertEqual(local.model, translation(-189, 22, 3))
        assertEqual(local.view, matrix_identity_float4x4)
        assertEqual(local.projection, compositeProjection)
    }

    /// 1920×1080 canvas, V = I, fov 90°: D = (1/(2/1080))/tan 45° = 540, far = max(15000, 1540).
    func testPerspectiveAtTopLevelPushesR22Q5ViewAndProjection() {
        let emitter = WPEParityLayerTransform(id: "e", origin: .zero)
        let matrices = WPEParityParticleMatrices.draw(transforms([emitter], fov: 90), objectID: "e",
                                                      modelMatrix: translation(9, 8, 7), perspective: true,
                                                      compositeOwnerID: nil, parallax: canvas / 2)
        assertEqual(matrices.model, translation(9, 8, 7))
        assertEqual(matrices.view, translation(-960, -540, -540))
        let expected = simd_float4x4(rows: [
            SIMD4(0.5625, 0, 0, 0), SIMD4(0, 1, 0, 0),
            SIMD4(0, 0, 0.00033344448, 5.00166722), SIMD4(0, 0, -1, 0),
        ])
        assertEqual(matrices.projection, expected, accuracy: 1e-5)
    }

    /// Inside a 400×300 composite the current P has m5 = 2/300, so D = 150; W·cx stays the scene's 960.
    func testPerspectiveInCompositeUsesOwnerOrthoDistance() {
        let owner = WPEParityLayerTransform(id: "p", origin: .zero, size: SIMD2(400, 300))
        let emitter = WPEParityLayerTransform(id: "e", parentID: "p", origin: .zero)
        let matrices = WPEParityParticleMatrices.draw(transforms([owner, emitter], fov: 90), objectID: "e",
                                                      modelMatrix: translation(9, 8, 7), perspective: true,
                                                      compositeOwnerID: "p", parallax: canvas / 2)
        assertEqual(matrices.model, translation(9, 8, 7))
        assertEqual(matrices.view, translation(-960, -540, -150))
        XCTAssertEqual(matrices.projection.columns.2.z, 5 / Float(14995), accuracy: 1e-6)
    }

    // MARK: Renderer orientation fields

    func testRendererAxisDefaultsAndFixedUp() throws {
        let absent = try renderer(#"{"name": "rope"}"#)
        assertEqual(absent.axis, SIMD3(0, 1, 0))
        assertEqual(absent.fixedUp, SIMD3(0, 0, -1))
        XCTAssertFalse(absent.worldAxes)
        let zero = try renderer(#"{"axis": "0 0 0", "flags": 3}"#)
        assertEqual(zero.axis, SIMD3(0, 1, 0))
        XCTAssertTrue(zero.worldAxes)
        let down = try renderer(#"{"axis": "0 -3 0"}"#)
        assertEqual(down.axis, SIMD3(0, -1, 0))
        assertEqual(down.fixedUp, SIMD3(0, 0, -1))
        let x = try renderer(#"{"axis": "2 0 0", "flags": 2}"#)
        assertEqual(x.axis, SIMD3(1, 0, 0))
        assertEqual(x.fixedUp, SIMD3(0, 1, 0))
        XCTAssertFalse(x.worldAxes)
        let diagonal = try renderer(#"{"axis": "1 1 0"}"#)
        assertEqual(diagonal.fixedUp, SIMD3(-s, s, 0))
    }

    // MARK: Orientation

    /// Scene V = Rz(90°): row0 = (0, −1, 0), row1 = (1, 0, 0), row2 = (0, 0, 1), so VF = (0, 0, −1), VU = (1, 0, 0).
    private var rotatedView: simd_float4x4 {
        simd_float4x4(simd_quatf(angle: .pi / 2, axis: SIMD3(0, 0, 1)))
    }

    private func vectors(_ json: String, model: simd_float3x3 = matrix_identity_float3x3)
        throws -> (forward: SIMD3<Float>, right: SIMD3<Float>, up: SIMD3<Float>) {
        try WPEParityParticleOrientation.vectors(renderer: renderer(json), modelRotation: model,
                                                 sceneView: rotatedView)
    }

    func testScreenOrientation() throws {
        let model = try vectors(#"{"orientation": "screen"}"#)
        assertEqual(model.forward, SIMD3(0, 0, 1))
        assertEqual(model.up, SIMD3(0, 1, 0))
        assertEqual(model.right, SIMD3(1, 0, 0))
        let view = try vectors(#"{"orientation": "screen", "flags": 1}"#)
        assertEqual(view.forward, SIMD3(0, 0, 1))
        assertEqual(view.up, SIMD3(1, 0, 0))
        assertEqual(view.right, SIMD3(0, -1, 0))
    }

    func testUprightOrientation() throws {
        let model = try vectors(#"{"orientation": "upright", "axis": "1 0 0"}"#)
        assertEqual(model.up, SIMD3(1, 0, 0))
        assertEqual(model.forward, SIMD3(0, 0, 1))
        assertEqual(model.right, SIMD3(0, -1, 0))
        let world = try vectors(#"{"orientation": "upright", "axis": "1 0 0", "flags": 1}"#)
        assertEqual(world.up, SIMD3(0, 1, 0))
        assertEqual(world.forward, SIMD3(0, 0, 1))
        assertEqual(world.right, SIMD3(1, 0, 0))
    }

    func testFixedOrientationWithRotatedModel() throws {
        let rotation = simd_float3x3(simd_quatf(angle: .pi / 2, axis: SIMD3(0, 0, 1)))
        // Without bit0, F = M3·a then F' = M3ᵀ·M3·a = a.
        let model = try vectors(#"{"orientation": "fixed", "axis": "1 0 0"}"#, model: rotation)
        assertEqual(model.forward, SIMD3(1, 0, 0))
        assertEqual(model.up, SIMD3(0, 1, 0))
        assertEqual(model.right, SIMD3(0, 0, -1))
        // With bit0, F' = Rz(−90°)·a.
        let world = try vectors(#"{"orientation": "fixed", "axis": "1 0 0", "flags": 1}"#, model: rotation)
        assertEqual(world.forward, SIMD3(0, -1, 0))
        assertEqual(world.up, SIMD3(1, 0, 0))
        assertEqual(world.right, SIMD3(0, 0, -1))
    }

    /// M3 = Rz(90°)·diag(2, 1, 1), rows (0, −1, 0), (2, 0, 0), (0, 0, 1); a = (s, s, 0), b = (−s, s, 0).
    /// M3ᵀa ∝ (2, −1, 0); the inverse would give (1, −2, 0).
    func testNonUniformScaleUsesTranspose() throws {
        let model = simd_float3x3(rows: [SIMD3(0, -1, 0), SIMD3(2, 0, 0), SIMD3(0, 0, 1)])
        let result = try vectors(#"{"orientation": "fixed", "axis": "1 1 0", "flags": 1}"#, model: model)
        let root5 = Float(5).squareRoot()
        assertEqual(result.forward, SIMD3(2, -1, 0) / root5)
        assertEqual(result.up, SIMD3(2, 1, 0) / root5)
        assertEqual(result.right, SIMD3(0, 0, -1))
    }

    // MARK: RenderVar state

    /// RN:97 ropetrail draw: RV0 = (0.005, 100, 0.1585, 3.5) with xy left by the rain spritetrail.
    func testRopeTrailKeepsSpriteTrailXY() {
        var state = WPEParityRenderVarState()
        XCTAssertEqual(state.rv0, .zero)
        XCTAssertEqual(state.rv1, .zero)
        state.apply(WPEParityRenderVar0(x: 0.005, y: 100, z: 0))
        state.apply(WPEParityRenderVar0(z: 0.1585, w: 3.5))
        XCTAssertEqual(state.rv0, SIMD4(0.005, 100, 0.1585, 3.5))
        state.setRV1(SIMD4(1, 2, 3, 4))
        XCTAssertEqual(state.rv1, SIMD4(1, 2, 3, 4))
        XCTAssertEqual(state.rv0, SIMD4(0.005, 100, 0.1585, 3.5))
    }

    /// 1024×256 sheet, four 256×128 frames: UV (0.25, 0.5), count 4, (256/1024)·(0.5/0.25) = 0.5 = 128/256.
    func testSpriteSheetRV1ForFourFrames() {
        let frame = WPEParityUniformSpriteFrame(x: 0, y: 0, widthX: 256, widthY: 0, heightX: 0, heightY: 128,
                                                imageWidth: 1024, imageHeight: 256)
        let texture = WPEParityUniformTexture(textureWidth: 1024, textureHeight: 256, imageWidth: 1024,
                                              imageHeight: 256, mipMapInfo: 1, spriteFrame: frame)
        XCTAssertEqual(WPEParityRenderVarState.spriteSheetRV1(texture: texture, frameCount: 4),
                       SIMD4(0.25, 0.5, 4, 0.5))
        let plain = WPEParityUniformTexture(textureWidth: 1024, textureHeight: 256, imageWidth: 1024,
                                            imageHeight: 256, mipMapInfo: 1)
        XCTAssertNil(WPEParityRenderVarState.spriteSheetRV1(texture: plain, frameCount: 4))
    }
}
