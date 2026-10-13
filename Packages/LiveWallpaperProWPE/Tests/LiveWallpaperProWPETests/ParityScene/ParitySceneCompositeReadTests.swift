@testable import LiveWallpaperProWPE
import XCTest

/// Cross-layer composite reads, dependency targets and shape quads in the scene frame.
final class ParitySceneCompositeReadTests: XCTestCase {
    private typealias Fixtures = ParitySceneFixtures
    private let compositeA: WPEResourceID = "_rt_imageLayerComposite_A_a"

    /// A is a dependency target; B's albedo material samples A's composite.
    private func twoLayers(visibleA: Bool = true) -> WPEParitySceneDescription {
        var a = Fixtures.layer("A", sortKey: 0, visible: visibleA)
        a.dependencyTarget = true
        var b = Fixtures.layer("B", sortKey: 1)
        b.material = WPEParitySceneMaterialSource(materialPath: "materials/b.json")
        b.materialFrameReads = ["materials/b.json": [compositeA, "_rt_imageLayerComposite_A_b"]]
        return Fixtures.scene([a, b])
    }

    func testDrawSamplingAnotherLayersCompositeListsTheRead() throws {
        let frame = WPEParitySceneFrameBuilder.build(twoLayers())
        let albedo = try XCTUnwrap(frame.draws["B/albedo"])
        // WPE names no `_b`, so that read stays out.
        XCTAssertEqual(albedo.reads, ["B/image", compositeA])
        XCTAssertTrue(frame.resources.contains { $0.id == compositeA })
        XCTAssertEqual(frame.samplers[compositeA], WPEParitySceneSampler(filter: .linear, address: .clamp))
        XCTAssertEqual(Fixtures.lines(frame), [
            Fixtures.sceneBind, Fixtures.sceneClear[0], Fixtures.sceneClear[1],
            "bind \(compositeA)", "draw genericimage2 [A/image] normal rgba quad",
            "bind backbuffer|backbufferDepth",
            "draw effectpassthrough_4 [\(compositeA),_rt_FullFrameBuffer] translucent rgb mesh",
            "bind backbuffer|backbufferDepth", "draw genericimage2 [B/image,\(compositeA)] translucent rgb mesh",
        ])
    }

    func testReaderDrawnBeforeTheOwnerStillListsTheRead() {
        var scene = twoLayers()
        scene.objects[0].sortKey = 2
        let frame = WPEParitySceneFrameBuilder.build(scene)
        XCTAssertEqual(frame.draws["B/albedo"]?.reads, ["B/image", compositeA])
    }

    /// 1401ea2d0: a hidden dependency target still fills its composite every frame; only its scene draw goes, and
    /// the passes that fill the composite have no owner, so the renderer keeps them while the layer is hidden.
    func testHiddenDependencyTargetKeepsFillingItsComposite() {
        let frame = WPEParitySceneFrameBuilder.build(twoLayers(visibleA: false))
        XCTAssertEqual(frame.draws["A/albedo"]?.target, compositeA)
        XCTAssertNil(frame.owners["A/albedo"])
        XCTAssertNil(frame.draws["A/passthrough4"])
        XCTAssertEqual(frame.draws["B/albedo"]?.reads, ["B/image", compositeA])
        XCTAssertEqual(frame.owners["B/albedo"], "B")

        let visible = WPEParitySceneFrameBuilder.build(twoLayers())
        XCTAssertNil(visible.owners["A/albedo"])
        XCTAssertEqual(visible.owners["A/passthrough4"], "A")
    }

    func testHiddenOrdinaryLayerLeavesItsReaderOnPreservedEntryHistory() throws {
        var scene = twoLayers(visibleA: false)
        scene.objects[0].dependencyTarget = false
        scene.objects[0].colorBlendMode = 5
        let frame = WPEParitySceneFrameBuilder.build(scene)
        XCTAssertFalse(frame.draws.values.contains { $0.objectID == "A" })
        XCTAssertEqual(frame.draws["B/albedo"]?.reads, ["B/image", compositeA])
        let graph = try WPERenderGraphCompiler.compile(resources: frame.resources, operations: frame.operations)
        XCTAssertEqual(graph.storage[compositeA], .dedicated)
        let reader = try XCTUnwrap(frame.operations.firstIndex { operation in
            guard operation.pass == "B/albedo", case .draw = operation.kind else { return false }
            return true
        })
        let history = try XCTUnwrap(graph.accesses[reader].reads.first { $0.subresource.resource == compositeA })
        XCTAssertEqual(history.revision, 0)
        XCTAssertNil(history.producer)
    }

    func testModelSubMeshListsTheCompositeItsMaterialNames() {
        var a = Fixtures.layer("A")
        a.dependencyTarget = true
        let mesh = WPEParitySceneModelMesh(material: WPEParitySceneMaterialSource(materialPath: "materials/m.json"),
                                           shader: "generic4", blend: .normal,
                                           materialState: WPEParitySceneMaterialState())
        let model = WPEParitySceneObject(id: "M", kind: .model(WPEParitySceneModel(meshes: [mesh])), sortKey: 1,
                                         width: 0, height: 0,
                                         materialFrameReads: ["materials/m.json": [compositeA]])
        let frame = WPEParitySceneFrameBuilder.build(Fixtures.scene([a, model]))
        XCTAssertEqual(frame.draws[WPEParitySceneModel.pass(objectID: "M", mesh: 0)]?.reads, [compositeA])
    }

    private func shape(points: [SIMD2<Float>]? = nil) -> WPEParitySceneObject {
        let passes = [
            WPEParityScenePass(shader: "effects/blur", target: "_rt_half", source: .init(materialPath: "m0.json")),
            WPEParityScenePass(shader: "effects/lightshafts", binds: ["_rt_half"],
                               blend: .translucent, source: .init(materialPath: "m1.json")),
        ]
        let effect = WPEParitySceneEffect(id: "E", passes: passes,
                                          fbos: [WPEParitySceneFBO(name: "_rt_half", width: 256, height: 128)])
        return WPEParitySceneObject(id: "S", kind: .shape(WPEParitySceneShape(points: points)), width: 512,
                                    height: 256, colorBlendMode: 9, effects: [effect])
    }

    /// W55: no albedo or composite; earlier passes draw the 2×2 quad, the last one the shape mesh additive, all with
    /// DIRECTDRAW=1, whatever colorBlendMode says.
    func testShapeQuadDrawsOnlyItsLastEffectsPasses() throws {
        let frame = WPEParitySceneFrameBuilder.build(Fixtures.scene([shape()]))
        XCTAssertEqual(Fixtures.lines(frame), [
            Fixtures.sceneBind, Fixtures.sceneClear[0], Fixtures.sceneClear[1],
            "bind _rt_half_256_128_1", "draw effects/blur [] normal rgba quad",
            "bind backbuffer|backbufferDepth", "draw effects/lightshafts [_rt_half_256_128_1] additive rgb shape",
        ])
        let first = try XCTUnwrap(frame.draws["S/E/0"])
        XCTAssertTrue(first.layerMatrices)
        XCTAssertEqual(first.source?.combos["DIRECTDRAW"], 1)
        let last = try XCTUnwrap(frame.draws["S/E/1"])
        XCTAssertFalse(last.layerMatrices)
        XCTAssertEqual(last.source?.combos["DIRECTDRAW"], 1)
    }

    func testShapeMeshWithoutPointsIsTheCentredLayerQuad() {
        let mesh = WPEParitySceneShape()
        XCTAssertEqual(mesh.vertices(width: 512, height: 256).map(\.position),
                       [SIMD3(-256, 128, 0), SIMD3(256, 128, 0), SIMD3(-256, -128, 0), SIMD3(256, -128, 0)])
        XCTAssertEqual(mesh.vertices(width: 512, height: 256).map(\.texcoord),
                       [SIMD2(0, 0), SIMD2(1, 0), SIMD2(0, 1), SIMD2(1, 1)])
        XCTAssertEqual(mesh.indices, [0, 2, 1, 1, 2, 3])
    }

    func testShapeMeshWithPointsIsAFanOverThem() {
        let points: [SIMD2<Float>] = [SIMD2(0.25, 0), SIMD2(1, 0.5), SIMD2(0.5, 1), SIMD2(0, 0.75)]
        let mesh = WPEParitySceneShape(points: points)
        XCTAssertEqual(mesh.vertices(width: 400, height: 200).map(\.position),
                       [SIMD3(-100, 100, 0), SIMD3(200, 0, 0), SIMD3(0, -100, 0), SIMD3(-200, -50, 0)])
        XCTAssertEqual(mesh.vertices(width: 400, height: 200).map(\.texcoord), points)
        XCTAssertEqual(mesh.indices, [0, 2, 1, 0, 3, 2])
    }
}
