import Foundation
@testable import LiveWallpaperProWPE
import XCTest

final class ParityTextPipelineTests: XCTestCase {
    private static func makePipeline() throws -> WPEParityTextPipeline {
        _ = try ParityTextPlannerTests.makePlanner()
        return WPEParityTextPipeline(assets: WPEParityProgramAssets(sources: [.directory(ParityFontChainTests.assetsRoot)]),
                                     hdr: false, orthographic: true)
    }

    private static func object(_ id: String, _ text: String, pointSize: Double = 32) -> WPEParityTextObject {
        WPEParityTextObject(json: .object([
            "id": .string(id), "text": .string(text), "font": .string(ParityFontChainTests.notoSans),
            "pointsize": .number(pointSize),
        ]))
    }

    /// Every quad's UVs are its glyph's entry in the atlas as it is now.
    private static func assertUVsMatchAtlas(_ pipeline: WPEParityTextPipeline, _ id: String,
                                            file: StaticString = #filePath, line: UInt = #line) throws {
        let text = try XCTUnwrap(pipeline.texts[id], file: file, line: line)
        let mesh = try XCTUnwrap(text.layout.mesh, file: file, line: line)
        let atlas = try XCTUnwrap(pipeline.atlases[text.atlasKey], file: file, line: line).mono
        for (quad, glyph) in mesh.mono.glyphKeys.enumerated() {
            let uv = try XCTUnwrap(atlas.entry(forKey: glyph), "\(id) glyph \(glyph)", file: file, line: line).uv
            let corners = mesh.mono.vertices[quad * 4 ..< quad * 4 + 4].map { SIMD2($0.u, $0.v) }
            XCTAssertEqual(corners, [SIMD2(uv.x, uv.y), SIMD2(uv.z, uv.y), SIMD2(uv.x, uv.w), SIMD2(uv.z, uv.w)],
                           "\(id) quad \(quad)", file: file, line: line)
        }
    }

    func testRelayoutReplacesOnlyTheChangedLayer() throws {
        let pipeline = try Self.makePipeline()
        pipeline.add(Self.object("T", "Hi"), effectCount: 0)
        pipeline.add(Self.object("U", "iH"), effectCount: 0)
        pipeline.refreshUVs()
        let other = pipeline.texts["U"]
        let key = try XCTUnwrap(pipeline.texts["T"]?.atlasKey)
        XCTAssertEqual(pipeline.atlases[key]?.mono.takeDirty(), true)

        XCTAssertEqual(pipeline.relayout(Self.object("T", "Hello")), ["T"])
        let fresh = try Self.makePipeline()
        fresh.add(Self.object("T", "Hello"), effectCount: 0)
        let expected = try XCTUnwrap(fresh.texts["T"]?.layout.mesh)
        let relaid = try XCTUnwrap(pipeline.texts["T"]?.layout.mesh)
        XCTAssertEqual(relaid.mono.vertices.map { SIMD2($0.x, $0.y) }, expected.mono.vertices.map { SIMD2($0.x, $0.y) })
        XCTAssertEqual(relaid.mono.glyphKeys, expected.mono.glyphKeys)
        XCTAssertEqual(pipeline.texts["U"], other)
        XCTAssertEqual(pipeline.atlases[key]?.mono.isDirty, true, "new glyphs were packed")
        try Self.assertUVsMatchAtlas(pipeline, "T")
        try Self.assertUVsMatchAtlas(pipeline, "U")

        XCTAssertEqual(pipeline.atlases[key]?.mono.takeDirty(), true)
        XCTAssertEqual(pipeline.relayout(Self.object("T", "Hello")), [], "the same fields change nothing")
        XCTAssertEqual(pipeline.relayout(Self.object("T", "Hell")), ["T"])
        XCTAssertEqual(pipeline.atlases[key]?.mono.isDirty, false, "glyphs already packed are not packed again")
    }

    func testEachGlyphIsRenderedOnce() throws {
        _ = try ParityTextPlannerTests.makePlanner()
        let library = WPEParityFontLibrary(assets: WPEParityProgramAssets(sources: [.directory(ParityFontChainTests.assetsRoot)]))
        let face = try XCTUnwrap(library.chain(fontPath: ParityFontChainTests.notoSans, pointSize: 32).faces.first)
        let layout = WPEParityTextLayoutEngine.layout(Self.object("T", "Hello").layoutInput(effectCount: 0),
                                                      fonts: library)
        let keys = try XCTUnwrap(layout.mesh?.mono.glyphKeys)
        XCTAssertEqual(face.renders, Set(keys).count, "layout renders each glyph once")
        var atlas = WPEParityGlyphAtlas(format: .r8)
        for key in keys where atlas.entry(forKey: key) == nil {
            _ = try atlas.insert(key: key, bitmap: XCTUnwrap(face.rasterize(key & 0xFFFFFF)))
        }
        XCTAssertEqual(face.renders, Set(keys).count, "the atlas takes layout's renders")
    }

    /// 256 pt NotoSans glyphs fill a 4096² atlas in a few dozen glyphs; a second set that cannot evict the first
    /// resets it.
    func testAtlasResetRelaysEveryLayerOnIt() throws {
        let pipeline = try Self.makePipeline()
        pipeline.add(Self.object("A", "ABCDEFGHIJKLMNOP", pointSize: 256), effectCount: 0)
        pipeline.add(Self.object("B", "ab", pointSize: 256), effectCount: 0)
        pipeline.refreshUVs()
        let key = try XCTUnwrap(pipeline.texts["A"]?.atlasKey)
        var changed: [String] = []
        for text in ["QRSTUVWXYZ0123456789", "WMQGOD@%&#$WMQGOD", "mwqgdbhkpyMWQGBDHK"] {
            changed = pipeline.relayout(Self.object("A", text, pointSize: 256))
            if changed.contains("B") {
                break
            }
        }
        print("atlas \(key): size \(pipeline.atlases[key]?.mono.width ?? 0), changed \(changed)")
        XCTAssertEqual(changed, ["A", "B"], "a reset lays out every layer on the atlas")
        try Self.assertUVsMatchAtlas(pipeline, "A")
        try Self.assertUVsMatchAtlas(pipeline, "B")
    }

    func testFrameShapeKeepsTheFBOSizeOnlyThroughAnFBO() throws {
        let pipeline = try Self.makePipeline()
        pipeline.add(Self.object("D", "Hi"), effectCount: 0)
        pipeline.add(Self.object("F", "Hi"), effectCount: 1)
        XCTAssertTrue(pipeline.keepsFrameShape(Self.object("D", "Hello")))
        XCTAssertFalse(pipeline.keepsFrameShape(Self.object("F", "Hello")))
        XCTAssertTrue(pipeline.keepsFrameShape(Self.object("F", "Hi")))
        XCTAssertFalse(pipeline.keepsFrameShape(Self.object("D", "")), "the glyph list goes away")
    }

    func testTextLayoutFieldsBindLiveAndTheUpdateCarriesTheLayer() throws {
        _ = try ParityTextPlannerTests.makePlanner()
        func document(_ caption: String?) throws -> WPESceneDocument {
            let scene: [String: Any] = [
                "camera": ["center": "0 0 0"],
                "general": ["orthogonalprojection": ["width": 1920, "height": 1080]],
                "objects": [[
                    "id": 5, "name": "clock", "text": ["user": "caption", "value": "Hi"],
                    "font": ParityFontChainTests.notoSans, "pointsize": 32,
                    "backgroundcolor": ["user": "back", "value": "0 0 0"], "origin": "960 540 0",
                ]],
            ]
            return try WPESceneDocumentParser.parse(data: JSONSerialization.data(withJSONObject: scene),
                                                    userValues: caption.map { ["caption": .string($0)] } ?? [:],
                                                    makeTransformScriptResolver: { _, _ in PipelineNoScripts() })
        }
        let old = try document(nil)
        let bindings = WPEParityUserProperties.bindings(document: old)
        XCTAssertEqual(bindings["caption"]?.map(\.action), [.incremental])
        XCTAssertEqual(bindings["caption"]?.first?.target, .textObject(id: "5"))
        XCTAssertEqual(bindings["back"]?.map(\.action), [.reload])
        let update = try XCTUnwrap(WPEParityUserPropertyUpdate(from: old, to: document("Hello")))
        XCTAssertEqual(update.texts.map(\.text), ["Hello"])
        XCTAssertEqual(try XCTUnwrap(WPEParityUserPropertyUpdate(from: old, to: document(nil))).texts, [])
    }
}

private struct PipelineNoScripts: WPESceneTransformScriptResolving {
    func resolveVec3(script _: String, properties _: [String: WPESceneScriptPropertyValue],
                     seed _: SIMD3<Double>) -> SIMD3<Double>? {
        nil
    }
}
