import Foundation
@testable import LiveWallpaperProWPE
import XCTest

/// Text layer operations on a synthetic scene with the WPE assets' NotoSans.
final class ParitySceneTextTests: XCTestCase {
    private typealias Fixtures = ParitySceneFixtures

    private func sceneText(_ object: WPEParityTextObject, effectCount: Int = 0,
                           orthographic: Bool = true) throws -> WPEParitySceneText {
        let planner = try ParityTextPlannerTests.makePlanner()
        let (layout, key) = planner.plan(object, effectCount: effectCount)
        return WPEParitySceneText(object: object, effectCount: effectCount, layout: layout, atlasKey: key, hdr: false,
                                  orthographic: orthographic)
    }

    /// (kind, shader, target, blend) of each operation after the scene clear.
    private func steps(_ frame: WPEParitySceneFrame) -> [String] {
        frame.operations.dropFirst(3).map { operation in
            switch operation.kind {
            case let .setTargets(color, _): "bind \(color.map(\.resource.rawValue).joined(separator: "|"))"
            case let .clearColor(view, color):
                "clear \(view.resource) \(color.red),\(color.green),\(color.blue),\(color.alpha)"
            case let .copy(source, destination): "copy \(source)->\(destination)"
            case .draw:
                frame.draws[operation.pass].map { "draw \($0.shader) \($0.target) \($0.blend.rawValue)" } ?? "draw ?"
            default: "\(operation.kind)"
            }
        }
    }

    private func composite(_ text: WPEParitySceneText, index: Int = 0) -> String {
        "sc.\(max(4, text.layout.fboSize.x)).\(max(4, text.layout.fboSize.y)).bc\(index)"
    }

    func testDirectTextDrawsItsGlyphsIntoTheScene() throws {
        let text = try sceneText(ParityTextPlannerTests.textObject())
        let frame = WPEParitySceneFrameBuilder.build(Fixtures.scene([.text(text)]))
        XCTAssertEqual(steps(frame), ["bind backbuffer", "draw font backbuffer translucent"])
        let glyphs = try XCTUnwrap(frame.draws["T/glyphs"])
        XCTAssertEqual(glyphs.source?.materialPath, "materials/fonts/basefont.json")
        XCTAssertEqual(glyphs.geometry, .textGlyphs(.mono))
        XCTAssertEqual(glyphs.writeMask, .rgb)
        XCTAssertEqual(frame.owners["T/glyphs"], "T")
        XCTAssertEqual(text.padding, .zero)
    }

    /// FUN_140258900: box + 2p, (2, 2) without a mesh; floats, not the Int FBO size.
    func testScriptSizeIsTheUntruncatedPaddedBox() {
        let mesh = WPEParityTextMesh(minX: -1.5, bottom: -20.25, maxX: 100.75, top: 30.5, lineHeight: 50,
                                     lineCount: 1, pointSize: 32)
        func size(_ mesh: WPEParityTextMesh?, effectCount: Int, padding: SIMD2<Float>? = nil) -> SIMD2<Float> {
            var object = ParityTextPlannerTests.textObject()
            if let padding {
                object.padding = padding
            }
            let layout = WPEParityTextLayout(mesh: mesh, blockOffset: .zero, fboSize: SIMD2(1, 1))
            return WPEParitySceneText(object: object, effectCount: effectCount, layout: layout, atlasKey: "",
                                      hdr: false, orthographic: true).scriptSize
        }
        XCTAssertEqual(size(mesh, effectCount: 0), SIMD2(102.25, 50.75))
        XCTAssertEqual(size(mesh, effectCount: 1), SIMD2(166.25, 114.75))
        XCTAssertEqual(size(mesh, effectCount: 1, padding: SIMD2(600, 10)), SIMD2(1126.25, 70.75))
        XCTAssertEqual(size(nil, effectCount: 0), SIMD2(2, 2))
        XCTAssertEqual(size(nil, effectCount: 1), SIMD2(66, 66))
    }

    func testTextWithAnEffectDrawsIntoItsPooledFBOFirst() throws {
        let text = try sceneText(ParityTextPlannerTests.textObject(), effectCount: 1)
        let frame = WPEParitySceneFrameBuilder.build(Fixtures.scene([.text(text, effects: [Fixtures.effect("E")])]))
        let fbo = composite(text)
        XCTAssertEqual(steps(frame), [
            "copy backbuffer->_rt_FullFrameBuffer",
            "bind \(fbo)", "draw composelayer \(fbo) normal",
            "bind \(fbo)", "draw font \(fbo) translucent",
            "bind backbuffer", "draw E backbuffer translucent",
        ])
        let resource = try XCTUnwrap(frame.resources.first { $0.id.rawValue == fbo })
        XCTAssertEqual(SIMD2(resource.width, resource.height), text.layout.fboSize)
        XCTAssertEqual(frame.draws["T/clearalpha"]?.source, .textClearAlpha)
        XCTAssertEqual(frame.draws["T/clearalpha"]?.reads, [WPEParitySceneResource.fullFrameBuffer])
        XCTAssertEqual(frame.draws["T/glyphs"]?.fillsComposite, true)
        XCTAssertEqual(frame.draws["T/glyphs"]?.writeMask, .rgba)
        XCTAssertEqual(frame.draws["T/E/0"]?.geometry, .layerMesh)
    }

    func testBit4TextCompositesThroughEffectPassthrough() throws {
        let text = try sceneText(ParityTextPlannerTests.textObject(colorBlendMode: 2))
        let frame = WPEParitySceneFrameBuilder.build(Fixtures.scene([.text(text)]))
        let fbo = WPEParitySceneResource.layerCompositeA("T").rawValue
        XCTAssertEqual(steps(frame), [
            "copy backbuffer->_rt_FullFrameBuffer",
            "bind \(fbo)", "draw composelayer \(fbo) normal",
            "bind \(fbo)", "draw font \(fbo) translucent",
            "bind backbuffer", "draw effectpassthrough_4 backbuffer translucent",
        ])
        let resource = try XCTUnwrap(frame.resources.first { $0.id.rawValue == fbo })
        XCTAssertEqual(SIMD2(resource.width, resource.height), text.layout.fboSize)
        XCTAssertEqual(frame.draws["T/passthrough4"]?.source?.combos, ["BLENDMODE": 2, "FOG_COMPUTED": 1])
        XCTAssertEqual(text.padding, SIMD2(32, 32))
    }

    func testOpaqueBackgroundDrawsTheBackgroundQuadOrClearsTheFBO() throws {
        let object = ParityTextPlannerTests.textObject(opaqueBackground: true)
        let direct = try sceneText(object)
        let frame = WPEParitySceneFrameBuilder.build(Fixtures.scene([.text(direct)]))
        XCTAssertEqual(steps(frame), [
            "bind backbuffer", "draw flat backbuffer translucent",
            "bind backbuffer", "draw font backbuffer translucent",
        ])
        XCTAssertEqual(frame.draws["T/background"]?.source?.materialPath, "materials/fonts/fontbackground.json")
        XCTAssertEqual(frame.draws["T/background"]?.geometry, .textBackground)

        let withEffect = try sceneText(object, effectCount: 1)
        let fbo = composite(withEffect)
        let effectFrame = WPEParitySceneFrameBuilder.build(Fixtures.scene([.text(withEffect,
                                                                                 effects: [Fixtures.effect("E")])]))
        XCTAssertEqual(steps(effectFrame), [
            "bind \(fbo)", "clear \(fbo) 0.0,0.0,0.0,1.0",
            "bind \(fbo)", "draw font \(fbo) translucent",
            "bind backbuffer", "draw E backbuffer translucent",
        ])
    }

    func testColorBlendMode31AddsTheGlyphs() throws {
        let additive = try sceneText(ParityTextPlannerTests.textObject(colorBlendMode: 31))
        XCTAssertEqual(WPEParitySceneFrameBuilder.build(Fixtures.scene([.text(additive)])).draws["T/glyphs"]?.blend,
                       .additive)
        let translucent = try sceneText(ParityTextPlannerTests.textObject(colorBlendMode: 0))
        XCTAssertEqual(WPEParitySceneFrameBuilder.build(Fixtures.scene([.text(translucent)])).draws["T/glyphs"]?.blend,
                       .translucent)
    }

    func testDepthMaterialsOnlyInPerspectiveScenesWithDepthTest() throws {
        func glyphMaterial(depthTest: String?, orthographic: Bool) throws -> String? {
            let object = ParityTextPlannerTests.textObject(depthTest: depthTest)
            let text = try sceneText(object, orthographic: orthographic)
            return WPEParitySceneFrameBuilder.build(Fixtures.scene([.text(text)])).draws["T/glyphs"]?.source?
                .materialPath
        }
        XCTAssertEqual(try glyphMaterial(depthTest: nil, orthographic: false), "materials/fonts/basefont_depth.json")
        XCTAssertEqual(try glyphMaterial(depthTest: "enabled", orthographic: true), "materials/fonts/basefont.json")
        XCTAssertEqual(try glyphMaterial(depthTest: "disabled", orthographic: false), "materials/fonts/basefont.json")
    }

    func testScenesWithoutTextKeepTheirOperations() throws {
        let layer = Fixtures.layer(effects: [Fixtures.effect("E")])
        var hidden = try WPEParitySceneObject.text(sceneText(ParityTextPlannerTests.textObject()), visible: false)
        hidden.sortKey = 1
        XCTAssertEqual(WPEParitySceneFrameBuilder.build(Fixtures.scene([layer, hidden])).operations,
                       WPEParitySceneFrameBuilder.build(Fixtures.scene([layer])).operations)
    }

    func testProgramSceneBindsTheLiveLayerColourAndTheAtlas() throws {
        _ = try ParityTextPlannerTests.makePlanner()
        let scene: [String: Any] = [
            "camera": ["center": "0 0 0"],
            "general": ["orthogonalprojection": ["width": 1920, "height": 1080]],
            "objects": [[
                "id": 5, "name": "clock", "text": "Hi", "font": ParityFontChainTests.notoSans, "pointsize": 32,
                "color": "1 0.5 0.25", "alpha": 0.5, "origin": "960 540 0",
            ]],
        ]
        let document = try WPESceneDocumentParser.parse(data: JSONSerialization.data(withJSONObject: scene),
                                                        userValues: [:],
                                                        makeTransformScriptResolver: { _, _ in TextNoScripts() })
        let assets = WPEParityProgramAssets(sources: [.directory(ParityFontChainTests.assetsRoot)])
        let program = WPEParityProgramScene(document: document, assets: assets, settings: WPEParityProgramSettings())
        guard case let .text(text)? = program.scene.objects.first?.kind else { return XCTFail("no text object") }
        XCTAssertNotNil(program.textAtlases[text.atlasKey])
        XCTAssertEqual(program.textSizes["5"], SIMD2(Float(text.layout.fboSize.x), Float(text.layout.fboSize.y)))

        let frame = try WPEParityFrameComposer.compose(scene: program.scene, post: program.postProcess, frameIndex: 0)
        let index = try XCTUnwrap(frame.operations.firstIndex { $0.pass == "5/glyphs" && $0.kind.isDraw })
        let binding = try XCTUnwrap(WPEParityProgramBuilder.bindings(frame: frame, scene: program)[index])
        XCTAssertEqual(binding.layerColorObjectID, "5")
        XCTAssertEqual(binding.textures[0], .textAtlas(key: text.atlasKey, atlas: .mono))
        guard case let .vector(color)? = binding.constants[.fragment]?["g_Color4"] else {
            return XCTFail("no g_Color4")
        }
        XCTAssertEqual(color, [1, 0.5, 0.25, 0.5])

        let state = WPEParitySceneState(scene: program, document: document)
        XCTAssertEqual(state.object("5")?.alpha, 0.5)
        XCTAssertEqual(state.object("5")?.origin, SIMD3(960, 540, 0))
    }

    func testProgramSceneAdmitsFieldTextsInTwoFontsWithZeroAreaSpaces() throws {
        _ = try ParityTextPlannerTests.makePlanner()
        let roboto = "fonts/RobotoMono-Regular.ttf"
        let scene: [String: Any] = [
            "camera": ["center": "0 0 0"],
            "general": ["orthogonalprojection": ["width": 1920, "height": 1080]],
            "objects": [
                ["id": 41, "name": "date", "text": "16 OCT 2026", "font": ParityFontChainTests.notoSans,
                 "pointsize": 32, "dropshadow": true, "origin": "960 540 0"],
                ["id": 48, "name": "day", "text": "T H U", "font": roboto,
                 "pointsize": 32, "dropshadow": true, "origin": "960 640 0"],
            ],
        ]
        let document = try WPESceneDocumentParser.parse(data: JSONSerialization.data(withJSONObject: scene),
                                                        userValues: [:],
                                                        makeTransformScriptResolver: { _, _ in TextNoScripts() })
        let assets = WPEParityProgramAssets(sources: [.directory(ParityFontChainTests.assetsRoot)])
        let program = WPEParityProgramScene(document: document, assets: assets, settings: WPEParityProgramSettings())
        XCTAssertNil(program.textPreparationFailure)
        var texts: [String: WPEParitySceneText] = [:]
        for object in program.scene.objects {
            if case let .text(text) = object.kind {
                texts[object.id] = text
            }
        }
        XCTAssertEqual(Set(texts.keys), ["41", "48"])
        XCTAssertEqual(texts.values.map { $0.layout.mesh?.glyphMode }, [.distanceField, .distanceField])
        XCTAssertEqual(Set(program.textAtlases.keys), ["\(ParityFontChainTests.notoSans)_msdf", "\(roboto)_msdf"])
        let noto = try XCTUnwrap(texts["41"])
        let space = try XCTUnwrap(program.textAtlases[noto.atlasKey]?.mono.entry(forKey: 3))
        XCTAssertEqual([space.x1 - space.x0, space.y1 - space.y0], [24, 24])
        XCTAssertEqual(noto.layout.mesh?.mono.glyphKeys.filter { $0 == 3 }.count, 2)
    }
}

private struct TextNoScripts: WPESceneTransformScriptResolving {
    func resolveVec3(script _: String, properties _: [String: WPESceneScriptPropertyValue],
                     seed _: SIMD3<Double>) -> SIMD3<Double>? {
        nil
    }
}

private extension WPERenderOperation.Kind {
    var isDraw: Bool {
        if case .draw = self {
            true
        } else {
            false
        }
    }
}
