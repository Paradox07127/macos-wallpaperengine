import Foundation
import LiveWallpaperProWPE
import Testing
import XCTest

private typealias F = ParitySceneFixtures

struct ParitySceneEffectFBONameTests {
    private static func effect(_ id: String, _ fbos: [WPEParitySceneFBO]) -> WPEParitySceneEffect {
        WPEParitySceneEffect(id: id, passes: [
            WPEParityScenePass(shader: "write", target: fbos[0].name),
            WPEParityScenePass(shader: "read", binds: fbos.map(\.name)),
        ], fbos: fbos)
    }

    @Test func uniqueFBOTakesTheEffectIDAndOthersTheirSizeAndScale() {
        let effect = Self.effect("7", [
            WPEParitySceneFBO(name: "acc", width: 512, height: 256, unique: true),
            WPEParitySceneFBO(name: "half", width: 256, height: 128, unscaledSize: SIMD2(512, 256), scale: 2),
        ])
        let frame = WPEParitySceneFrameBuilder.build(F.scene([F.layer(effects: [effect])]))
        #expect(frame.draws["L/7/0"]?.target == "acc_7")
        #expect(frame.draws["L/7/1"]?.reads == [WPEResourceID(F.bc0), "acc_7", "half_512_256_2"])
        #expect(frame.resources.first { $0.id == "half_512_256_2" }.map { [$0.width, $0.height] } == [256, 128])
    }

    @Test func equalDeclarationsOnTwoLayersShareOneTextureUnlessUnique() {
        func layer(_ id: String, effectID: String) -> WPEParitySceneObject {
            F.layer(id, effects: [Self.effect(effectID, [
                WPEParitySceneFBO(name: "acc", width: 512, height: 256, unique: true),
                WPEParitySceneFBO(name: "tmp", width: 512, height: 256),
            ])])
        }
        let frame = WPEParitySceneFrameBuilder.build(F.scene([layer("A", effectID: "1"), layer("B", effectID: "2")]))
        let effectFBOs = frame.resources.map(\.id.rawValue).filter { !$0.hasPrefix("sc.") && !$0.contains("/") }
        #expect(effectFBOs.filter { $0 != "backbuffer" && $0 != "backbufferDepth" && !$0.hasPrefix("_rt_") }.sorted()
            == ["acc_1", "acc_2", "tmp_512_256_1"])
    }

    @Test func fullscreenLayerKeepsTheBareName() {
        var layer = F.layer(effects: [Self.effect("7", [WPEParitySceneFBO(name: "tmp", width: 1920, height: 1080)])])
        layer.fullscreen = true
        let frame = WPEParitySceneFrameBuilder.build(F.scene([layer]))
        #expect(frame.draws["L/7/0"]?.target == "tmp")
    }
}

struct ParitySceneLastEffectSegmentTests {
    @Test func passesOfTheLastEffectDrawWithTheLayerMatricesIntoTheDestination() {
        let last = WPEParitySceneEffect(id: "e2", passes: [
            WPEParityScenePass(shader: "pre", blend: .translucent),
            WPEParityScenePass(shader: "down", target: "half"),
            WPEParityScenePass(shader: "up", binds: ["half"]),
        ], fbos: [WPEParitySceneFBO(name: "half", width: 256, height: 128)])
        let frame = WPEParitySceneFrameBuilder.build(F.scene([F.layer(effects: [F.effect("e1"), last])]))
        #expect(Array(F.lines(frame).dropFirst(3)) == [
            "bind \(F.bc1)",
            "draw genericimage2 [L/image] normal rgba quad",
            "bind \(F.bc0)",
            "draw e1 [\(F.bc1)] normal rgba quad",
            F.sceneBind,
            "draw pre [\(F.bc0)] translucent rgba quad",
            "bind half_256_128_1",
            "draw down [\(F.bc0)] normal rgba quad",
            F.sceneBind,
            "draw up [\(F.bc0),half_256_128_1] translucent rgb mesh",
        ])
        let layered = frame.draws.values.filter(\.layerMatrices).map(\.pass.rawValue).sorted()
        #expect(layered == ["L/e2/0", "L/e2/1"])
        // The quad no longer covers its target, so the pass must load what is there.
        let down = frame.operations.first { $0.pass == "L/e2/1" && $0.isDraw }
        if case let .draw(operation)? = down?.kind {
            #expect(!operation.overwritesTargets)
        }
    }

    @Test func aComposePassInTheLastEffectStartsTheSegmentAfterIt() {
        let last = WPEParitySceneEffect(id: "e", passes: [
            WPEParityScenePass(shader: "a", compose: true), WPEParityScenePass(shader: "b"),
            WPEParityScenePass(shader: "c"),
        ])
        let frame = WPEParitySceneFrameBuilder.build(F.scene([F.layer(effects: [last])]))
        #expect(frame.draws["L/e/0"]?.layerMatrices == false)
        #expect(frame.draws["L/e/0"]?.target == WPEResourceID(F.bc0))
        #expect(frame.draws["L/e/1"]?.layerMatrices == true)
        #expect(frame.draws["L/e/1"]?.target == "backbuffer")
        #expect(frame.draws["L/e/2"]?.geometry == .layerMesh)
    }

    @Test func childLastSegmentUsesTheParentCompositeCamera() {
        let child = F.layer("C", parentID: "P", effects: [WPEParitySceneEffect(id: "e", passes: [
            WPEParityScenePass(shader: "a"), WPEParityScenePass(shader: "b"),
        ])])
        let frame = WPEParitySceneFrameBuilder.build(F.scene([F.layer("P", effects: [F.effect("pe")]), child]))
        #expect(frame.draws["C/e/0"]?.compositeOwnerID == "P")
        #expect(frame.draws["C/e/0"]?.layerMatrices == true)
    }

    @Test func bit4LayersKeepEveryPassInTheirComposites() {
        let effect = WPEParitySceneEffect(id: "e", passes: [WPEParityScenePass(shader: "a"),
                                                            WPEParityScenePass(shader: "b")])
        let frame = WPEParitySceneFrameBuilder.build(F.scene([F.layer(colorBlendMode: 5, effects: [effect])]))
        let layered = frame.draws.values.filter(\.layerMatrices)
        #expect(layered.isEmpty)
    }
}

struct ParityLastEffectPassMatricesTests {
    @Test func lastEffectPassTakesTheLayerMatricesOnTheTwoByTwoQuad() throws {
        let layer = WPEParityLayerTransform(id: "L", origin: SIMD3(300, 200, 0), scale: SIMD3(2, 1, 1),
                                            size: SIMD2(512, 256))
        let camera = WPEParityCamera(eye: SIMD3(960, 540, 1), center: SIMD3(960, 540, 0), up: SIMD3(0, 1, 0),
                                     size: SIMD2(1920, 1080), renderTargetSize: SIMD2(1920, 1080))
        let set = WPEParityLayerTransformSet(camera: camera, layers: [layer])
        let last = try set.draw("L", kind: .lastEffectPass, parallax: .zero)
        let final = try set.draw("L", kind: .layer, parallax: .zero)
        #expect(last.matrices.modelViewProjection == final.matrices.modelViewProjection)
        #expect(last.effectPass?.isLastPass == true)
        #expect(set.quad("L", kind: .lastEffectPass) == .effectPass)
        let intermediate = try set.draw("L", kind: .effectPass, parallax: .zero)
        #expect(intermediate.matrices.modelViewProjection != final.matrices.modelViewProjection)
    }
}

private extension WPERenderOperation {
    var isDraw: Bool {
        if case .draw = kind {
            true
        } else {
            false
        }
    }
}

/// Workshop 3808922316's motion blur declares `_rt_FullCompoBuffer1` unique and `_rt_FullCompoBuffer2` not.
final class ParitySceneUniqueFBOWorkshopTests: XCTestCase {
    func testMotionBlurFBOsTakeWPEPoolNames() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let package = home.appendingPathComponent(
            "Library/Application Support/Steam/steamapps/workshop/content/431960/3808922316/scene.pkg"
        )
        let wpeAssets = home.appendingPathComponent(
            "Library/Application Support/Steam/steamapps/common/wallpaper_engine/assets"
        )
        guard FileManager.default.fileExists(atPath: package.path),
              FileManager.default.fileExists(atPath: wpeAssets.appendingPathComponent("materials/util").path) else {
            throw XCTSkip("Workshop 3808922316 or the WPE assets are not installed")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("parity-unique-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try ParityProgramPuppetTests.unpack(package, into: root)
        let document = try WPESceneDocumentParser.parse(data: Data(contentsOf: root.appendingPathComponent("scene.json")),
                                                        userValues: [:],
                                                        makeTransformScriptResolver: { _, _ in NoScripts() })
        let scene = WPEParityProgramScene(document: document, assets: WPEParityProgramAssets(sceneDirectory: root,
                                                                                             assetRoots: [wpeAssets]),
                                          settings: WPEParityProgramSettings())
        let frame = WPEParitySceneFrameBuilder.build(scene.scene)
        let ids = Set(frame.resources.map(\.id.rawValue))
        var checked = 0
        for object in scene.scene.objects where object.visible {
            for effect in object.effects where effect.enabled {
                for fbo in effect.fbos where fbo.name.hasPrefix("_rt_FullCompoBuffer") && !fbo.shared {
                    let expected = fbo.unique ? "\(fbo.name)_\(effect.id)"
                        : object.fullscreen ? fbo.name : "\(fbo.name)_\(object.width)_\(object.height)_1"
                    XCTAssertEqual(fbo.unique, fbo.name == "_rt_FullCompoBuffer1", "\(object.id)/\(effect.id)")
                    XCTAssertTrue(ids.contains(expected), "\(object.id)/\(effect.id): \(expected)")
                    checked += 1
                }
            }
        }
        print("3808922316: \(checked) motion-blur FBOs, \(frame.draws.values.count(where: \.layerMatrices)) "
            + "last-segment quads with layer matrices")
        XCTAssertGreaterThan(checked, 0)
        // A raw scene keeps possible sampler reads; post owns the declaration after shader preparation.
        // Supply that preparation fact here without inferring activity from a source annotation.
        var post = scene.postProcess
        post.sceneMipMappedFrameBufferEnabled = true
        let composed = try WPEParityFrameComposer.compose(scene: scene.scene, post: post, frameIndex: 0)
        XCTAssertTrue(composed.resources.contains { $0.id == "_rt_MipMappedFrameBuffer" })
        _ = try WPERenderGraphCompiler.compile(resources: composed.resources, operations: composed.operations)
    }
}

private struct NoScripts: WPESceneTransformScriptResolving {
    func resolveVec3(script _: String, properties _: [String: WPESceneScriptPropertyValue],
                     seed _: SIMD3<Double>) -> SIMD3<Double>? {
        nil
    }
}
