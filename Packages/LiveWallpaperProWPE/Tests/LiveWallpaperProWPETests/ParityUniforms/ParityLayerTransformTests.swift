@testable import LiveWallpaperProWPE
import simd
import XCTest

final class ParityLayerTransformTests: XCTestCase {
    func testTextPerspectiveAndLiveCoordinateFieldsShareLayerMatrices() throws {
        let document = try ParityCameraFixture.document(json: """
        {"camera":{"eye":"0 0 0","center":"0 0 -1","up":"0 1 0"},
         "general":{"orthogonalprojection":{"width":200,"height":100}},
         "objects":[{"id":1,"text":"sample","origin":"100 50 0","perspective":{"value":true},
                     "parallaxDepth":"0.25 0.5"}]}
        """)
        var layers = WPEParityLayerTransformSet(document: document, renderTargetSize: SIMD2(200, 100),
                                                textSizes: ["1": SIMD2(40, 20)])
        XCTAssertEqual(layers.layers["1"]?.perspective, true)
        XCTAssertEqual(try layers.projection("1"), try layers.camera.perspectiveProjection)
        var state = WPEParitySceneState(document: document, hdr: false)
        XCTAssertFalse(layers.applyFields(state: state))
        state.setScriptField("perspective", of: "1", to: .vector(.zero), invalidating: .none)
        state.setScriptField("parallaxDepth", of: "1", to: .vector(SIMD4(0.5, 0.75, 0, 0)), invalidating: .none)
        XCTAssertTrue(layers.applyFields(state: state))
        XCTAssertEqual(layers.layers["1"]?.parallaxDepth, SIMD2(0.5, 0.75))
        XCTAssertEqual(try layers.projection("1"), layers.camera.projection)
        XCTAssertFalse(layers.applyFields(state: state), "unchanged state does not invalidate draw placement")
    }

    private let canvas = SIMD2<Float>(3840, 2160)

    private func assertEqual(_ lhs: simd_float4x4, _ rhs: simd_float4x4, accuracy: Float = 1e-4,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(simd_almost_equal_elements(lhs, rhs, accuracy), "\(lhs) != \(rhs)", file: file, line: line)
    }

    private func translation(_ x: Float, _ y: Float, _ z: Float = 0) -> simd_float4x4 {
        var matrix = matrix_identity_float4x4
        matrix.columns.3 = SIMD4(x, y, z, 1)
        return matrix
    }

    private func layer(_ id: String, parent: String? = nil, origin: SIMD3<Float> = .zero,
                       angles: SIMD3<Float> = .zero, scale: SIMD3<Float> = .one, size: SIMD2<Float> = SIMD2(200, 100),
                       alignment: WPEParityLayerAlignment = .center) -> WPEParityLayerTransform {
        WPEParityLayerTransform(id: id, parentID: parent, origin: origin, angles: angles, scale: scale, size: size,
                                alignment: alignment)
    }

    private func set(_ layers: [WPEParityLayerTransform]) -> WPEParityLayerTransformSet {
        let camera = WPEParityCamera(eye: .zero, center: SIMD3(0, 0, -1), up: SIMD3(0, 1, 0), size: canvas,
                                     renderTargetSize: canvas)
        return WPEParityLayerTransformSet(camera: camera, layers: layers)
    }

    func testObject935ModelAndPackedModelViewProjection() throws {
        let document = try ParityCameraFixture.scene3660962877()
        let layers = WPEParityLayerTransformSet(document: document, renderTargetSize: canvas)
        let angle: Float = -1.5708
        let rotation = simd_float4x4(rows: [
            SIMD4(cos(angle), -sin(angle), 0, 0), SIMD4(sin(angle), cos(angle), 0, 0),
            SIMD4(0, 0, 1, 0), SIMD4(0, 0, 0, 1),
        ])
        let expected = translation(373.25635, 864.29602) * rotation
            * simd_float4x4(diagonal: SIMD4(5.99649, 1.97301, 1, 1))
        assertEqual(layers.model("935"), expected, accuracy: 1e-5)

        let draw = try layers.draw("935", kind: .layer, parallax: canvas / 2)
        guard case let .matrix(packed)? = draw.matrices.values["g_ModelViewProjectionMatrix"] else {
            return XCTFail("no g_ModelViewProjectionMatrix")
        }
        let registers: [[Float]] = [
            [-1.15e-8, 1.02761e-3, 0, -0.805596], [-5.55231e-3, -6.7e-9, 0, -0.199726],
            [0, 0, 2.5e-4, 0.5], [0, 0, 0, 1],
        ]
        for (register, expected) in registers.enumerated() {
            for component in 0 ..< 4 {
                XCTAssertEqual(packed.columns[register][component], expected[component], accuracy: 1e-5,
                               "c\(register).\(component)")
            }
        }
    }

    func testLocalIsTranslateRotateZYXScale() {
        let angles = SIMD3<Float>(0.3, -0.7, 1.1)
        let local = layer("a", origin: SIMD3(5, 6, 7), angles: angles, scale: SIMD3(2, 3, 4)).local
        func rotation(_ angle: Float, _ axis: SIMD3<Float>) -> simd_float4x4 {
            simd_float4x4(simd_quatf(angle: angle, axis: axis))
        }
        let expected = translation(5, 6, 7) * rotation(angles.z, SIMD3(0, 0, 1)) * rotation(angles.y, SIMD3(0, 1, 0))
            * rotation(angles.x, SIMD3(1, 0, 0)) * simd_float4x4(diagonal: SIMD4(2, 3, 4, 1))
        assertEqual(local, expected)
    }

    func testAlignmentOffsetsForAllNineValues() {
        let size = SIMD2<Float>(200, 100)
        let expected: [WPEParityLayerAlignment: SIMD2<Float>] = [
            .center: SIMD2(0, 0), .top: SIMD2(0, -50), .topRight: SIMD2(-100, -50), .right: SIMD2(-100, 0),
            .bottomRight: SIMD2(-100, 50), .bottom: SIMD2(0, 50), .bottomLeft: SIMD2(100, 50), .left: SIMD2(100, 0),
            .topLeft: SIMD2(100, -50),
        ]
        XCTAssertEqual(WPEParityLayerAlignment.allCases.map(\.rawValue), Array(0 ... 8))
        for alignment in WPEParityLayerAlignment.allCases {
            XCTAssertEqual(alignment.offset(size: size), expected[alignment], "\(alignment)")
        }
        XCTAssertEqual(WPEParityLayerAlignment(.bottomLeft), .bottomLeft)
        XCTAssertEqual(WPEParityLayerAlignment(.topRight), .topRight)
    }

    func testAlignmentOffsetIsLocalBeforeScaleAndRotation() {
        let aligned = layer("a", origin: SIMD3(1000, 500, 0), angles: SIMD3(0, 0, .pi / 2), scale: SIMD3(2, 2, 1),
                            alignment: .topLeft)
        let layers = set([aligned])
        // Local offset (100, -50), scaled by 2 and rotated +90°: (100, 200).
        let corner = layers.model("a") * SIMD4<Float>(0, 0, 0, 1)
        XCTAssertEqual(corner.x, 1100, accuracy: 1e-3)
        XCTAssertEqual(corner.y, 700, accuracy: 1e-3)
    }

    func testChildDoesNotInheritParentAlignment() {
        let parent = layer("p", origin: SIMD3(1000, 500, 0), alignment: .topLeft)
        let child = layer("c", parent: "p", origin: SIMD3(10, 20, 0))
        let layers = set([parent, child])
        assertEqual(layers.world("p"), translation(1000, 500))
        assertEqual(layers.model("p"), translation(1100, 450))
        assertEqual(layers.model("c"), translation(1010, 520))
    }

    func testParentComposesOnTheLeft() {
        let parent = layer("p", origin: SIMD3(1000, 500, 0), angles: SIMD3(0, 0, .pi / 2), scale: SIMD3(2, 2, 1))
        let child = layer("c", parent: "p", origin: SIMD3(10, 0, 0))
        let layers = set([child, parent])
        let expected = parent.local * child.local
        assertEqual(layers.world("c"), expected)
        let origin = layers.world("c") * SIMD4<Float>(0, 0, 0, 1)
        XCTAssertEqual(origin.x, 1000, accuracy: 1e-3)
        XCTAssertEqual(origin.y, 520, accuracy: 1e-3)
        // Negative control: the swapped order is a different matrix, so the check above can fail.
        XCTAssertFalse(simd_almost_equal_elements(layers.world("c"), child.local * parent.local, 1e-2))
    }

    func testChildInParentCompositeUsesInverseParentModel() throws {
        let parent = layer("p", origin: SIMD3(1000, 500, 0), angles: SIMD3(0, 0, 0.4), size: SIMD2(400, 300),
                           alignment: .left)
        let child = layer("c", parent: "p", origin: SIMD3(30, 40, 0))
        let layers = set([parent, child])
        let draw = try layers.draw("c", kind: .layer, compositeOwnerID: "p", parallax: canvas / 2)
        assertEqual(draw.matrices.model, layers.model("p").inverse * layers.model("c"))
        assertEqual(draw.matrices.view, matrix_identity_float4x4)
        assertEqual(draw.matrices.projection, WPEParityUniformMatrices.ortho(halfWidth: 200, halfHeight: 150,
                                                                             depth: 1000))
    }

    /// R10: a grandchild drawn through a parent without a composite is P_owner·inverse(W'_owner)·W'_grandchild.
    func testGrandchildInGrandparentCompositeUsesOwnerMatrices() throws {
        let owner = layer("g", origin: SIMD3(1000, 500, 0), angles: SIMD3(0, 0, 0.4), size: SIMD2(400, 300),
                          alignment: .left)
        let parent = layer("p", parent: "g", origin: SIMD3(-50, 20, 0), angles: SIMD3(0, 0, 0.2),
                           scale: SIMD3(1.5, 1.5, 1), size: SIMD2(100, 80))
        let child = layer("c", parent: "p", origin: SIMD3(30, 40, 0))
        let layers = set([owner, parent, child])
        let draw = try layers.draw("c", kind: .layer, compositeOwnerID: "g", parallax: canvas / 2)
        let expected = WPEParityUniformMatrices.ortho(halfWidth: 200, halfHeight: 150, depth: 1000)
            * layers.model("g").inverse * layers.model("c")
        assertEqual(draw.matrices.modelViewProjection, expected, accuracy: 1e-6)
        // Negative control: the direct parent's composite matrices differ, so the check above can fail.
        let direct = WPEParityLayerTransform.compositeMatrices(parentModel: layers.model("p"), parentSize: parent.size,
                                                               childModel: layers.model("c"))
        XCTAssertFalse(simd_almost_equal_elements(direct.modelViewProjection, expected, 1e-3))
    }

    /// R10 step 1, capture eid144: the albedo fills a 3756×1936 composite with M = V = I and a y-up ortho.
    func testAlbedoIntoCompositeMatchesCaptureEid144() throws {
        let layers = set([layer("a", origin: SIMD3(1920, 1080, 0), size: SIMD2(400, 200))])
        let kind = WPEParityLayerDrawKind.compositeFill(size: SIMD2(3756, 1936))
        let draw = try layers.draw("a", kind: kind, parallax: canvas / 2)
        var expected = simd_float4x4(diagonal: SIMD4(2.0 / 3756, 2.0 / 1936, 1.0 / 2000, 1))
        expected.columns.3 = SIMD4(-1, -1, 0.5, 1)
        assertEqual(draw.matrices.modelViewProjection, expected, accuracy: 1e-7)
        assertEqual(draw.matrices.model, matrix_identity_float4x4)
        assertEqual(draw.matrices.view, matrix_identity_float4x4)
        let quad = layers.quad("a", kind: kind, uvMax: SIMD2(0.75, 0.5))
        XCTAssertEqual(quad.vertices.map(\.position), [SIMD3(0, 1936, 0), SIMD3(3756, 1936, 0), SIMD3(0, 0, 0),
                                                       SIMD3(3756, 0, 0)])
        XCTAssertEqual(quad.vertices.map(\.texcoord), [SIMD2(0, 0), SIMD2(0.75, 0), SIMD2(0, 0.5), SIMD2(0.75, 0.5)])
        XCTAssertEqual((expected * SIMD4(quad.vertices[0].position, 1)).y, 1, accuracy: 1e-6)
    }

    func testLayerAndEffectPassDraws() throws {
        let layers = set([layer("a", origin: SIMD3(1920, 1080, 0), size: SIMD2(400, 200))])
        let final = try layers.draw("a", kind: .layer, parallax: canvas / 2)
        assertEqual(final.matrices.model, layers.model("a"))
        assertEqual(final.matrices.projection, layers.camera.projection)
        XCTAssertEqual(final.effectPass?.isLastPass, true)
        XCTAssertEqual(final.effectPass?.size, SIMD2(400, 200))
        let pass = try layers.draw("a", kind: .effectPass, parallax: canvas / 2)
        assertEqual(pass.matrices.modelViewProjection, WPEParityUniformMatrices.effectPass.modelViewProjection)
        XCTAssertEqual(pass.effectPass?.isLastPass, false)
        assertEqual(pass.effectPass?.layerModelViewProjection ?? .init(), final.matrices.modelViewProjection)
        XCTAssertEqual(layers.quad("a", kind: .layer), WPEParityLayerQuad.layer(size: SIMD2(400, 200)))
        XCTAssertEqual(layers.quad("a", kind: .effectPass), WPEParityLayerQuad.effectPass)
    }

    func testParallaxUsesTopmostAncestor() throws {
        var root = layer("r", origin: SIMD3(1000, 500, 0))
        root.parallaxDepth = SIMD2(1, 1)
        var child = layer("c", parent: "r", origin: SIMD3(50, 0, 0))
        child.parallaxDepth = SIMD2(4, 4)
        var camera = set([]).camera
        camera.parallaxAmount = 0.5
        let layers = WPEParityLayerTransformSet(camera: camera, layers: [root, child])
        let view = try layers.view("c", parallax: SIMD2(1920, 1080))
        XCTAssertEqual(view * SIMD4<Float>(0, 0, 0, 1), SIMD4(-460, -290, 0, 1))
    }

    func testPerspectiveLayerReplacesProjectionAndView() throws {
        var flagged = layer("a")
        flagged.perspective = true
        let layers = set([flagged])
        try assertEqual(layers.projection("a"), layers.camera.perspectiveProjection)
        try assertEqual(layers.view("a", parallax: .zero), layers.camera.perspectiveView)
    }
}
