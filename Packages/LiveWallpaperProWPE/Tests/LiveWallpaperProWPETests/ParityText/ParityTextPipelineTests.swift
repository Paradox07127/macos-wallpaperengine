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

    @discardableResult
    private static func relayout(_ pipeline: WPEParityTextPipeline, _ object: WPEParityTextObject,
                                 effectCount: Int? = nil) throws -> WPEParityTextRelayoutDelta {
        guard let prepared = try pipeline.prepareRelayouts([.init(object, effectCount: effectCount)]) else {
            return WPEParityTextRelayoutDelta(changes: [])
        }
        return try pipeline.accept(prepared)
    }

    private static func changedIDs(_ pipeline: WPEParityTextPipeline, _ object: WPEParityTextObject) throws -> [String] {
        try relayout(pipeline, object).changes.map(\.current.object.id)
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
        try pipeline.add(Self.object("T", "Hi"), effectCount: 0, glyphMode: .bitmap)
        try pipeline.add(Self.object("U", "iH"), effectCount: 0, glyphMode: .bitmap)
        pipeline.refreshUVs()
        let other = pipeline.texts["U"]
        let key = try XCTUnwrap(pipeline.texts["T"]?.atlasKey)
        XCTAssertEqual(pipeline.atlases[key]?.mono.takeDirty(), true)

        XCTAssertEqual(try Self.changedIDs(pipeline, Self.object("T", "Hello")), ["T"])
        let fresh = try Self.makePipeline()
        try fresh.add(Self.object("T", "Hello"), effectCount: 0, glyphMode: .bitmap)
        let expected = try XCTUnwrap(fresh.texts["T"]?.layout.mesh)
        let relaid = try XCTUnwrap(pipeline.texts["T"]?.layout.mesh)
        XCTAssertEqual(relaid.mono.vertices.map { SIMD2($0.x, $0.y) }, expected.mono.vertices.map { SIMD2($0.x, $0.y) })
        XCTAssertEqual(relaid.mono.glyphKeys, expected.mono.glyphKeys)
        XCTAssertEqual(pipeline.texts["U"], other)
        XCTAssertEqual(pipeline.atlases[key]?.mono.isDirty, true, "new glyphs were packed")
        try Self.assertUVsMatchAtlas(pipeline, "T")
        try Self.assertUVsMatchAtlas(pipeline, "U")

        XCTAssertEqual(pipeline.atlases[key]?.mono.takeDirty(), true)
        XCTAssertEqual(try Self.changedIDs(pipeline, Self.object("T", "Hello")), [], "the same fields change nothing")
        XCTAssertEqual(try Self.changedIDs(pipeline, Self.object("T", "Hell")), ["T"])
        XCTAssertEqual(pipeline.atlases[key]?.mono.isDirty, false, "glyphs already packed are not packed again")
    }

    func testEachGlyphIsRenderedOnce() throws {
        _ = try ParityTextPlannerTests.makePlanner()
        let library = WPEParityFontLibrary(assets: WPEParityProgramAssets(sources: [.directory(ParityFontChainTests.assetsRoot)]))
        let face = try XCTUnwrap(library.chain(fontPath: ParityFontChainTests.notoSans, pointSize: 32).faces.first)
        let layout = try WPEParityTextLayoutEngine.layout(Self.object("T", "Hello").layoutInput(effectCount: 0),
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
    /// resets it. WPE's reset only clears the shelves and marks entries stale, leaving other layers' meshes
    /// (1401b0410.c:1095-1214), so B keeps UVs into the cleared atlas.
    func testAtlasResetLeavesOtherLayersAsTheyWere() throws {
        let pipeline = try Self.makePipeline()
        try pipeline.add(Self.object("A", "ABCDEFGHIJKLMNOP", pointSize: 256), effectCount: 0, glyphMode: .bitmap)
        try pipeline.add(Self.object("B", "ab", pointSize: 256), effectCount: 0, glyphMode: .bitmap)
        pipeline.refreshUVs()
        let key = try XCTUnwrap(pipeline.texts["A"]?.atlasKey)
        let other = try XCTUnwrap(pipeline.texts["B"])
        let otherGlyphs = try XCTUnwrap(other.layout.mesh?.mono.glyphKeys)
        var changed: [String] = []
        var reset = false
        for text in ["QRSTUVWXYZ0123456789", "WMQGOD@%&#$WMQGOD", "mwqgdbhkpyMWQGBDHK"] {
            changed = try Self.changedIDs(pipeline, Self.object("A", text, pointSize: 256))
            let atlas = try XCTUnwrap(pipeline.atlases[key]).mono
            if otherGlyphs.contains(where: { atlas.entry(forKey: $0) == nil }) {
                reset = true
                break
            }
        }
        XCTAssertTrue(reset, "the atlas never reset")
        XCTAssertEqual(changed, ["A"])
        XCTAssertEqual(pipeline.texts["B"], other)
        try Self.assertUVsMatchAtlas(pipeline, "A")
    }

    func testRelayoutDeltaCarriesDrawAndFBOChangesWithoutSpeculativeLayout() throws {
        let pipeline = try Self.makePipeline()
        try pipeline.add(Self.object("D", "Hi"), effectCount: 0, glyphMode: .bitmap)
        try pipeline.add(Self.object("F", "Hi"), effectCount: 1, glyphMode: .bitmap)
        let key = try XCTUnwrap(pipeline.texts["D"]?.atlasKey)
        _ = pipeline.atlases[key]?.mono.takeDirty()
        let version = pipeline.atlases[key]?.mono.contentGeneration
        XCTAssertTrue(try Self.relayout(pipeline, Self.object("D", "Hi")).changes.isEmpty)
        XCTAssertEqual(pipeline.atlases[key]?.mono.contentGeneration, version)
        XCTAssertFalse(try XCTUnwrap(pipeline.atlases[key]).mono.isDirty)

        let direct = try XCTUnwrap(Self.relayout(pipeline, Self.object("D", "Hello")).changes.first)
        XCTAssertEqual(direct.previous.object.text, "Hi")
        XCTAssertEqual(direct.current.object.text, "Hello")
        XCTAssertFalse(direct.requiresFrameRebuild, "direct glyphs can be repacked in the existing draw")
        XCTAssertNotEqual(direct.current.layout.fboSize, direct.previous.layout.fboSize)

        let composite = try XCTUnwrap(Self.relayout(pipeline, Self.object("F", "Hello")).changes.first)
        XCTAssertTrue(composite.requiresFrameRebuild, "the effect FBO must grow with its text")
        XCTAssertNotEqual(composite.current.layout.fboSize, composite.previous.layout.fboSize)

        let empty = try XCTUnwrap(Self.relayout(pipeline, Self.object("D", "")).changes.first)
        XCTAssertTrue(empty.requiresFrameRebuild, "the glyph draw goes away")
        XCTAssertNil(empty.current.layout.mesh)

        let effects = try XCTUnwrap(Self.relayout(pipeline, Self.object("F", "Hello"), effectCount: 0).changes.first)
        XCTAssertTrue(effects.requiresFrameRebuild)
        XCTAssertEqual(effects.current.effectCount, 0)
        XCTAssertEqual(effects.current.padding, .zero)
        XCTAssertNotEqual(effects.current.layout.fboSize, effects.previous.layout.fboSize)
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
                                                    userValues: caption.map { ["caption": .string($0)] } ?? [:])
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
