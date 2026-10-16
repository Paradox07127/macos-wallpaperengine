@testable import LiveWallpaperProWPE
import XCTest

/// WPE's shadow batch (140196530) ahead of RenderScene: casters draw into `_rt_shadowAtlas`, receivers sample it.
final class ParitySceneShadowTests: XCTestCase {
    private typealias Fixtures = ParitySceneFixtures
    private let atlas = WPEParitySceneResource.shadowAtlas

    private func mesh(_ shader: String, _ blend: WPEParitySceneBlend, _ path: String) -> WPEParitySceneModelMesh {
        WPEParitySceneModelMesh(material: WPEParitySceneMaterialSource(materialPath: path), shader: shader,
                                blend: blend)
    }

    /// M: [generic4 normal receiver, generic4 translucent, foliage4 normal, generic4 alphaToCoverage]; N never casts.
    private func scene(shadowAtlas: Bool = true, castsShadow: Bool = true,
                       extra: [WPEParitySceneObject] = []) -> WPEParitySceneDescription {
        let model = WPEParitySceneModel(meshes: [
            mesh("generic4", .normal, "materials/m0.json"),
            mesh("generic4", .translucent, "materials/m1.json"),
            mesh("foliage4", .normal, "materials/m2.json"),
            mesh("generic4", .alphaToCoverage, "materials/m3.json"),
        ], castsShadow: castsShadow)
        let m = WPEParitySceneObject(id: "M", kind: .model(model), width: 0, height: 0,
                                     materialFrameReads: ["materials/m0.json": [atlas]])
        let n = WPEParitySceneObject(id: "N", kind: .model(WPEParitySceneModel(meshes: [
            mesh("generic4", .normal, "materials/n.json"),
        ])), sortKey: 1, width: 0, height: 0)
        var scene = Fixtures.scene([m, n] + extra)
        scene.shadowAtlas = shadowAtlas
        return scene
    }

    private func drawIndex(_ frame: WPEParitySceneFrame, _ pass: WPEPassIdentity) throws -> Int {
        try XCTUnwrap(frame.operations.firstIndex { operation in
            guard operation.pass == pass, case .draw = operation.kind else { return false }
            return true
        })
    }

    func testCastersDrawIntoTheClearedAtlasBeforeTheScene() throws {
        let frame = WPEParitySceneFrameBuilder.build(scene())
        XCTAssertEqual(Array(Fixtures.lines(frame).prefix(5)), [
            "bind _rt_shadowAtlas", "clearDepth _rt_shadowAtlas 0.0", "bind _rt_shadowAtlas",
            "draw shadowcaster [] normal rgba model", Fixtures.sceneBind,
        ])
        XCTAssertEqual(frame.draws.values.filter { $0.target == atlas }.count, 1)
        let casterPass = WPEParitySceneModel.shadowPass(objectID: "M", mesh: 0)
        XCTAssertEqual(casterPass, "M/shadow/mesh0")
        let caster = try XCTUnwrap(frame.draws[casterPass])
        XCTAssertEqual(caster.source, WPEParitySceneMaterialSource(materialPath: "materials/util/shadowcaster.json"))
        XCTAssertTrue(caster.depthTest)
        XCTAssertTrue(caster.depthWrite)
        XCTAssertEqual(frame.owners[casterPass], "M")
        XCTAssertNil(frame.owners["shadow"])
        let resource = try XCTUnwrap(frame.resources.first { $0.id == atlas })
        XCTAssertEqual(resource.lifetime, .imported)
        XCTAssertEqual(resource.format, WPEParitySceneResource.depthFormat)
        XCTAssertEqual(SIMD2(resource.width, resource.height), SIMD2(2, 2))
        XCTAssertEqual(frame.draws["M/mesh0"]?.reads, [atlas])
        XCTAssertEqual(WPEParitySceneModel.meshIndex(casterPass, objectID: "M"), 0)
        XCTAssertEqual(WPEParitySceneModel.meshIndex("M/mesh0", objectID: "M"), 0)
    }

    func testCasterStepHasOnlyTheClearedAtlasAsDepth() throws {
        let frame = WPEParitySceneFrameBuilder.build(scene())
        let graph = try WPERenderGraphCompiler.compile(resources: frame.resources, operations: frame.operations)
        let caster = try drawIndex(frame, "M/shadow/mesh0")
        let encoder = try XCTUnwrap(graph.steps.first { $0.operations.contains(caster) }?.encoder)
        XCTAssertEqual(encoder.colorAttachments, [])
        XCTAssertEqual(encoder.depthAttachment?.subresource.resource, atlas)
        XCTAssertEqual(encoder.depthAttachment?.load, .clear(.depth(0)))
        XCTAssertEqual(encoder.depthAttachment?.store, .store)
    }

    func testAtlasIsClearedBeforeItsReceiverWithoutCasters() throws {
        let frame = WPEParitySceneFrameBuilder.build(scene(castsShadow: false))
        XCTAssertFalse(frame.draws.values.contains { $0.target == atlas })
        let graph = try WPERenderGraphCompiler.compile(resources: frame.resources, operations: frame.operations)
        let receiver = try drawIndex(frame, "M/mesh0")
        let clearStep = try XCTUnwrap(graph.steps.firstIndex {
            $0.encoder?.depthAttachment?.subresource.resource == atlas
                && $0.encoder?.depthAttachment?.load == .clear(.depth(0))
        })
        let receiverStep = try XCTUnwrap(graph.steps.firstIndex { $0.operations.contains(receiver) })
        XCTAssertLessThan(clearStep, receiverStep)
    }

    func testWithoutTheShadowPassTheAtlasAppearsNowhere() {
        let frame = WPEParitySceneFrameBuilder.build(scene(shadowAtlas: false))
        let model = "bind backbuffer|backbufferDepth"
        XCTAssertEqual(Fixtures.lines(frame), [
            Fixtures.sceneBind, Fixtures.sceneClear[0], Fixtures.sceneClear[1],
            model, "draw generic4 [] normal rgb model",
            model, "draw generic4 [] translucent rgb model",
            model, "draw foliage4 [] normal rgb model",
            model, "draw generic4 [] alphatocoverage rgb model",
            model, "draw generic4 [] normal rgb model",
        ])
        XCTAssertFalse(frame.resources.contains { $0.id == atlas })
        XCTAssertFalse(frame.draws.values.contains { $0.reads.contains(atlas) })
    }

    /// OPEN: blend 3 casters draw with ALPHATOCOVERAGE=1 (140155fc0.c:261-271); none is emitted yet.
    func testAlphaToCoverageMeshCastsNothingYet() {
        let frame = WPEParitySceneFrameBuilder.build(scene())
        XCTAssertNil(frame.draws[WPEParitySceneModel.shadowPass(objectID: "M", mesh: 3)])
    }

    /// OPEN: foliage4 and fur4 name their own caster shaders (`// [PASS] shadow`); none is emitted yet.
    func testFoliageAndFurMeshesCastNothingYet() {
        var description = scene()
        guard case var .model(model) = description.objects[0].kind else { return XCTFail("M is a model") }
        model.meshes[0].shader = "fur4"
        description.objects[0].kind = .model(model)
        let frame = WPEParitySceneFrameBuilder.build(description)
        XCTAssertFalse(frame.draws.values.contains { $0.target == atlas })
    }

    /// OPEN: genericparticle samples the atlas as g_Texture4, but particle draws do not list material frame reads.
    func testParticleReceiverDoesNotListTheAtlasYet() {
        let draw = WPEParitySceneParticleDraw(
            key: WPEParityParticleDrawKey(objectID: "P", node: [], renderer: 0), shader: "genericparticle",
            source: WPEParitySceneMaterialSource(materialPath: "materials/p.json"), blend: .additive,
            materialState: WPEParitySceneMaterialState(), readsFullFrameBuffer: false
        )
        let particle = WPEParitySceneObject(id: "P", kind: .particle(WPEParitySceneParticle(draws: [draw])),
                                            sortKey: 2, width: 0, height: 0,
                                            materialFrameReads: ["materials/p.json": [atlas]])
        let frame = WPEParitySceneFrameBuilder.build(scene(extra: [particle]))
        XCTAssertFalse(frame.draws.values.contains { $0.objectID == "P" && $0.reads.contains(atlas) })
        XCTAssertTrue(frame.draws.values.contains { $0.objectID == "P" })
    }
}
