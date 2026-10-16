import CryptoKit
import Foundation
@testable import LiveWallpaperProWPE
import XCTest

/// Same-owner value transactions. Synthetic atlas fill tests isolation, never an original pixel oracle.
final class ParityTextPreparedTransactionTests: XCTestCase {
    func testDiscardedPlannerResetKeepsActivePixelsReferencesAndCounters() throws {
        let assets = try assets(), planner = WPEParityTextPlanner(assets: assets)
        let key = WPEParityGlyphAtlasInstance.key(fontPath: "NotoSans-Regular.ttf", pointSize: 8)
        let protected: UInt32 = 0x00FF_FFFE
        var instance = WPEParityGlyphAtlasInstance(fontPath: "NotoSans-Regular.ttf", pointSize: 8)
        // Deterministically full4096 R8, one protected cell. A real H insertion must take the existing reset path.
        _ = try XCTUnwrap(instance.mono.insert(key: protected,
                                               bitmap: WPEParityGlyphBitmap(width: 4095, rows: 4095, pixelMode: .gray,
                                                                            pixels: [UInt8](repeating: 77, count: 4095 * 4095))))
        instance.mono.retain([protected])
        planner.atlases = [key: instance]
        var heldMesh = WPEParityTextMesh(minX: 0, bottom: 0, maxX: 4095, top: 4095,
                                         lineHeight: 1, lineCount: 1, pointSize: 8)
        heldMesh.mono.appendQuad(key: protected, x0: 0, x1: 4095, top: 4095, bottom: 0)
        heldMesh.mono.atlasResetGeneration = instance.mono.resetGeneration
        planner.adopt(objectID: "protected", layout: .init(mesh: heldMesh, blockOffset: .zero,
                                                           fboSize: SIMD2(4095, 4095)), atlasKey: key)
        let oldPixels = hash(instance.mono.pixels), oldEntry = instance.mono.entry(forKey: protected)
        let pending = try planner.prepare(object("T", "H"), effectCount: 0)
        XCTAssertEqual(pending.atlases[key]?.mono.resetGeneration, instance.mono.resetGeneration + 1)
        XCTAssertNil(pending.atlases[key]?.mono.entry(forKey: protected))
        XCTAssertNotNil(pending.atlases[key]?.mono.entry(forKey: 43))
        XCTAssertNotEqual(try hash(XCTUnwrap(pending.atlases[key]).mono.pixels), oldPixels)
        XCTAssertEqual(planner.atlases[key]?.mono.entry(forKey: protected), oldEntry)
        XCTAssertEqual(planner.atlases[key]?.mono.entry(forKey: protected)?.references, 1)
        XCTAssertEqual(try hash(XCTUnwrap(planner.atlases[key]).mono.pixels), oldPixels)
        XCTAssertEqual(planner.atlases[key]?.mono.resetGeneration, instance.mono.resetGeneration)
    }

    func testPipelineStagesLayoutAtlasAndReferencesUntilOneAccept() throws {
        let pipeline = try WPEParityTextPipeline(assets: assets(), hdr: false, orthographic: true)
        try pipeline.add(object("T", "H"), effectCount: 0, glyphMode: .bitmap)
        try pipeline.add(object("U", "H"), effectCount: 0, glyphMode: .bitmap)
        pipeline.refreshUVs()
        let before = pipeline.texts, oldKey = try XCTUnwrap(before["T"]).atlasKey
        let pending = try XCTUnwrap(pipeline.prepareRelayouts([.init(object("T", "HH"), glyphMode: .distanceField)]))
        let newKey = try XCTUnwrap(pending.texts["T"]).atlasKey
        XCTAssertEqual(pipeline.texts, before)
        XCTAssertNil(pipeline.atlases[newKey])
        XCTAssertEqual(pipeline.atlases[oldKey]?.mono.entry(forKey: 43)?.references, 2)
        XCTAssertEqual(pending.atlases[oldKey]?.mono.entry(forKey: 43)?.references, 1)
        XCTAssertEqual(pending.atlases[newKey]?.mono.entry(forKey: 43)?.references, 2)
        XCTAssertEqual(pending.texts["T"]?.layout.mesh?.mono.glyphKeys, [43, 43])
        XCTAssertTrue(try XCTUnwrap(pending.delta.changes.first).requiresFrameRebuild)
        // A GPU uploader receives values: mutating its private copy cannot change active or pending pixels/refs.
        let stagedPixels = try hash(XCTUnwrap(pending.atlases[newKey]).mono.pixels)
        var uploadCopy = pending.atlases
        uploadCopy[newKey]?.mono.reset()
        _ = uploadCopy[newKey]?.mono.insert(key: 999,
                                            bitmap: WPEParityGlyphBitmap(width: 1, rows: 1, pixelMode: .rgba, pixels: [1, 2, 3, 4]))
        XCTAssertEqual(try hash(XCTUnwrap(pending.atlases[newKey]).mono.pixels), stagedPixels)
        XCTAssertEqual(pending.atlases[newKey]?.mono.entry(forKey: 43)?.references, 2)
        try pipeline.discard(pending) // Simulated material/texture/geometry preparation failure.
        XCTAssertEqual(pipeline.texts, before)
        XCTAssertEqual(pipeline.atlases[oldKey]?.mono.entry(forKey: 43)?.references, 2)
        XCTAssertNil(pipeline.atlases[newKey])
        assertError(.preparedUpdateConsumed) { _ = try pipeline.accept(pending) }
        let accepted = try XCTUnwrap(pipeline.prepareRelayouts([.init(object("T", "HH"), glyphMode: .distanceField)]))
        let delta = try pipeline.accept(accepted)
        XCTAssertEqual(delta.changes.map(\.current.object.id), ["T"])
        XCTAssertEqual(pipeline.texts, accepted.texts)
        XCTAssertEqual(pipeline.atlases[newKey]?.mono.entry(forKey: 43)?.references, 2)
        XCTAssertEqual(pipeline.atlases[oldKey]?.mono.entry(forKey: 43)?.references, 1)
        assertError(.preparedUpdateConsumed) { _ = try pipeline.accept(accepted) }
        let empty = try XCTUnwrap(pipeline.prepareRelayouts([.init(object("T", ""), glyphMode: .distanceField)]))
        _ = try pipeline.accept(empty)
        XCTAssertEqual(pipeline.atlases[newKey]?.mono.entry(forKey: 43)?.references, 0)
        XCTAssertEqual(pipeline.texts["U"], before["U"])
    }

    func testPipelineParameterOnlyAcceptInvalidatesOlderGeometryWithoutRegeneratingFields() throws {
        let pipeline = try WPEParityTextPipeline(assets: assets(), hdr: false, orthographic: true)
        try pipeline.add(object("T", "H"), effectCount: 0, glyphMode: .bitmap)
        let initial = try XCTUnwrap(pipeline.prepareRelayouts([.init(object("T", "H"), glyphMode: .distanceField)]))
        _ = try pipeline.accept(initial)
        let original = try XCTUnwrap(pipeline.texts["T"]), key = original.atlasKey
        let version = pipeline.atlases[key]?.mono.contentGeneration
        let older = try XCTUnwrap(pipeline.prepareRelayouts([.init(object("T", "HH"), glyphMode: .distanceField)]))
        var colored = original.object; colored.outlineColor = SIMD3(0.2, 0.3, 0.4)
        let constants = try XCTUnwrap(pipeline.prepareRelayouts([.init(colored, glyphMode: .distanceField)]))
        XCTAssertEqual(pipeline.texts["T"], original)
        XCTAssertEqual(constants.texts["T"]?.layout, original.layout)
        XCTAssertEqual(constants.atlases[key]?.mono.contentGeneration, version)
        XCTAssertFalse(try XCTUnwrap(constants.delta.changes.first).requiresFrameRebuild)
        _ = try pipeline.accept(constants)
        assertError(.stalePreparedUpdate) { _ = try pipeline.accept(older) }
        XCTAssertEqual(pipeline.texts["T"]?.object.outlineColor, colored.outlineColor)
        XCTAssertEqual(pipeline.texts["T"]?.layout, original.layout)
        XCTAssertEqual(pipeline.atlases[key]?.mono.contentGeneration, version)
        XCTAssertEqual(pipeline.atlases[key]?.mono.entry(forKey: 43)?.references, 1)
        try pipeline.discard(older)
    }

    func testAtlasWritebackAndForeignPipelineCannotPublishPendingState() throws {
        let assets = try assets(), pipeline = WPEParityTextPipeline(assets: assets, hdr: false, orthographic: true)
        try pipeline.add(object("T", "H"), effectCount: 0, glyphMode: .bitmap)
        let before = pipeline.texts
        let late = try XCTUnwrap(pipeline.prepareRelayouts([.init(object("T", "HH"))]))
        var uploaded = pipeline.atlases
        let key = try XCTUnwrap(before["T"]).atlasKey
        _ = uploaded[key]?.mono.takeDirty()
        pipeline.atlases = uploaded
        assertError(.stalePreparedUpdate) { _ = try pipeline.accept(late) }
        XCTAssertEqual(pipeline.texts, before)
        XCTAssertEqual(pipeline.atlases[key]?.mono.entry(forKey: 43)?.references, 1)
        try pipeline.discard(late)
        let fresh = try XCTUnwrap(pipeline.prepareRelayouts([.init(object("T", "HH"))]))
        let foreign = WPEParityTextPipeline(assets: assets, hdr: false, orthographic: true)
        assertError(.foreignPreparedUpdate) { _ = try foreign.accept(fresh) }
        XCTAssertEqual(pipeline.texts, before)
        _ = try pipeline.accept(fresh)
        XCTAssertEqual(pipeline.texts["T"]?.object.text, "HH")
        assertError(.preparedUpdateConsumed) { try pipeline.discard(fresh) }
    }

    func testSecondBatchItemFailureKeepsFirstItemsPixelsReferencesAndLayoutsUnpublished() throws {
        let pipeline = try fieldPipeline()
        let before = pipeline.texts, key = try XCTUnwrap(before["T"]).atlasKey
        let oldAtlas = try XCTUnwrap(pipeline.atlases[key]), oldPixels = hash(oldAtlas.mono.pixels)
        let first = try XCTUnwrap(pipeline.prepareRelayouts([.init(object("T", "ii"), glyphMode: .distanceField)]))
        let newGlyph = try XCTUnwrap(first.texts["T"]?.layout.mesh?.mono.glyphKeys.first)
        XCTAssertNotEqual(newGlyph, 43)
        XCTAssertNotEqual(try hash(XCTUnwrap(first.atlases[key]).mono.pixels), oldPixels)
        XCTAssertEqual(first.atlases[key]?.mono.entry(forKey: 43)?.references, 1)
        XCTAssertEqual(first.atlases[key]?.mono.entry(forKey: newGlyph)?.references, 2)
        try pipeline.discard(first)
        assertError(.unqualifiedDistanceFieldGroup) {
            _ = try pipeline.prepareRelayouts([
                .init(self.object("T", "ii"), glyphMode: .distanceField),
                .init(self.object("U", "H你"), glyphMode: .distanceField),
            ])
        }
        XCTAssertEqual(pipeline.texts, before)
        XCTAssertEqual(try hash(XCTUnwrap(pipeline.atlases[key]).mono.pixels), oldPixels)
        XCTAssertEqual(pipeline.atlases[key]?.mono.contentGeneration, oldAtlas.mono.contentGeneration)
        XCTAssertEqual(pipeline.atlases[key]?.mono.resetGeneration, oldAtlas.mono.resetGeneration)
        XCTAssertEqual(pipeline.atlases[key]?.mono.entry(forKey: 43)?.references, 2)
        XCTAssertNil(pipeline.atlases[key]?.mono.entry(forKey: newGlyph))
        let batch = try XCTUnwrap(pipeline.prepareRelayouts([
            .init(object("T", "ii"), glyphMode: .distanceField),
            .init(object("U", "HHH"), glyphMode: .distanceField),
        ]))
        XCTAssertEqual(batch.changedObjectIDs, ["T", "U"])
        XCTAssertEqual(pipeline.texts, before)
        XCTAssertEqual(batch.atlases[key]?.mono.entry(forKey: 43)?.references, 3)
        XCTAssertEqual(batch.atlases[key]?.mono.entry(forKey: newGlyph)?.references, 2)
        let delta = try pipeline.accept(batch)
        XCTAssertEqual(delta.changes.map(\.current.object.id), ["T", "U"])
        XCTAssertEqual(pipeline.texts, batch.texts)
        XCTAssertEqual(pipeline.atlases[key]?.mono.entry(forKey: 43)?.references, 3)
        XCTAssertEqual(pipeline.atlases[key]?.mono.entry(forKey: newGlyph)?.references, 2)
        assertError(.preparedUpdateConsumed) { _ = try pipeline.accept(batch) }
    }

    func testOrderedBatchKeepsIntermediateAtlasWritesWhenOneTextReturnsToItsOriginalValue() throws {
        let pipeline = try fieldPipeline()
        let before = pipeline.texts, key = try XCTUnwrap(before["T"]).atlasKey
        let oldGeneration = try XCTUnwrap(pipeline.atlases[key]).mono.contentGeneration
        let intermediate = try XCTUnwrap(pipeline.prepareRelayouts([.init(object("T", "ii"), glyphMode: .distanceField)]))
        let newGlyph = try XCTUnwrap(intermediate.texts["T"]?.layout.mesh?.mono.glyphKeys.first)
        try pipeline.discard(intermediate)
        XCTAssertEqual(pipeline.atlases[key]?.mono.contentGeneration, oldGeneration)
        let batch = try XCTUnwrap(pipeline.prepareRelayouts([
            .init(object("T", "ii"), glyphMode: .distanceField),
            .init(object("U", "HH"), glyphMode: .distanceField),
            .init(object("T", "H"), glyphMode: .distanceField),
        ]))
        XCTAssertEqual(pipeline.texts, before)
        XCTAssertEqual(batch.texts["T"], before["T"])
        XCTAssertEqual(batch.delta.changes.map(\.current.object.id), ["U"])
        XCTAssertEqual(batch.changedObjectIDs, ["T", "U"], "intermediate dirty work is not lost with net-zero final text")
        XCTAssertEqual(batch.atlases[key]?.mono.contentGeneration, oldGeneration + 1)
        let zeroReferenceEntries = batch.atlases[key]?.mono.entry(forKey: newGlyph)
        XCTAssertNotNil(zeroReferenceEntries, "the intermediate glyph remains in its existing atlas owner")
        XCTAssertEqual(zeroReferenceEntries?.references, 0)
        _ = try pipeline.accept(batch)
        XCTAssertEqual(pipeline.texts["T"]?.object.text, "H")
        XCTAssertEqual(pipeline.texts["U"]?.object.text, "HH")
        XCTAssertEqual(pipeline.atlases[key]?.mono.entry(forKey: 43)?.references, 3)
        XCTAssertEqual(pipeline.atlases[key]?.mono.contentGeneration, oldGeneration + 1)
    }

    #if DEBUG
    /// The real font preflight and first object's numeric generation run normally. Only the second field
    /// output is injected, to qualify nil/atlas failure propagation and whole-batch state isolation.
    func testDistanceFieldGenerationAndTwoRoundAtlasFailureRejectWholeBatchThenRecover() throws {
        for atlasFailure in [false, true] {
            let pipeline = try fieldPipeline()
            let before = pipeline.texts, key = try XCTUnwrap(before["T"]).atlasKey
            let atlas = try XCTUnwrap(pipeline.atlases[key]).mono
            let probe = try XCTUnwrap(pipeline.prepareRelayouts([.init(object("T", "ii"), glyphMode: .distanceField)]))
            let newGlyph = try XCTUnwrap(probe.texts["T"]?.layout.mesh?.mono.glyphKeys.first)
            try pipeline.discard(probe)
            var calls = 0
            pipeline.fieldForTesting = { face, glyph in
                // The first staged glyph is still produced by the existing face and numeric bridge.
                if glyph == newGlyph & 0xFFFFFF {
                    return face.glyphField(glyph)
                }
                calls += 1
                guard atlasFailure, let original = face.glyphField(glyph) else { return nil }
                // Small synthetic tile with an impossible padded width; real atlas runs both rounds.
                // This is a failure fixture, never an original field/golden or a native resource cap.
                return WPEParityGlyphField(bitmap: .init(width: 4096, rows: 1, pixelMode: .rgba,
                                                         pixels: [UInt8](repeating: 0, count: 4096 * 4)),
                                           box: original.box, yPpem: original.yPpem, isColor: false,
                                           transform: original.transform, beforeCorrection: [], afterCorrection: [])
            }
            assertError(atlasFailure ? .distanceFieldAtlasAdmissionFailed : .distanceFieldGenerationFailed) {
                _ = try pipeline.prepareRelayouts([.init(self.object("T", "ii"), glyphMode: .distanceField),
                                                   .init(self.object("U", "M"), glyphMode: .distanceField)])
            }
            XCTAssertEqual(calls, atlasFailure ? 2 : 1, "Both real atlas rounds run; numeric nil fails immediately")
            XCTAssertEqual(pipeline.texts, before)
            let retained = try XCTUnwrap(pipeline.atlases[key]).mono
            XCTAssertEqual(hash(retained.pixels), hash(atlas.pixels))
            XCTAssertEqual(retained.width, atlas.width); XCTAssertEqual(retained.height, atlas.height)
            XCTAssertEqual(retained.contentGeneration, atlas.contentGeneration)
            XCTAssertEqual(retained.resetGeneration, atlas.resetGeneration)
            XCTAssertEqual(retained.entry(forKey: 43)?.references, 2)
            XCTAssertNil(retained.entry(forKey: newGlyph), "The earlier staged i must not leak after the second object fails")
            pipeline.fieldForTesting = nil
            let recovered = try XCTUnwrap(pipeline.prepareRelayouts([
                .init(object("T", "ii"), glyphMode: .distanceField),
                .init(object("U", "M"), glyphMode: .distanceField),
            ]))
            _ = try pipeline.accept(recovered)
            XCTAssertEqual(pipeline.texts["T"]?.object.text, "ii")
            XCTAssertEqual(pipeline.texts["U"]?.object.text, "M")
            XCTAssertEqual(pipeline.atlases[key]?.mono.entry(forKey: newGlyph)?.references, 2)
        }
    }
    #endif

    private func fieldPipeline() throws -> WPEParityTextPipeline {
        let pipeline = try WPEParityTextPipeline(assets: assets(), hdr: false, orthographic: true)
        try pipeline.add(object("T", "H"), effectCount: 0, glyphMode: .bitmap)
        try pipeline.add(object("U", "H"), effectCount: 0, glyphMode: .bitmap)
        let batch = try XCTUnwrap(pipeline.prepareRelayouts([
            .init(object("T", "H"), glyphMode: .distanceField),
            .init(object("U", "H"), glyphMode: .distanceField),
        ]))
        _ = try pipeline.accept(batch)
        return pipeline
    }

    private func object(_ id: String, _ text: String) -> WPEParityTextObject {
        WPEParityTextObject(json: .object(["id": .string(id), "text": .string(text),
                                           "font": .string("NotoSans-Regular.ttf"), "pointsize": .number(8), "msdf": .bool(true)]))
    }

    private func assets() throws -> WPEParityProgramAssets {
        guard let path = ProcessInfo.processInfo.environment["LOOMSCREEN_WPE_GLYPH_ORACLE_DIR"] else {
            throw XCTSkip("Set LOOMSCREEN_WPE_GLYPH_ORACLE_DIR to the original font fixture directory")
        }
        let root = URL(fileURLWithPath: path, isDirectory: true)
        let font = try Data(contentsOf: root.appendingPathComponent("NotoSans-Regular.ttf"))
        XCTAssertEqual(SHA256.hash(data: font).map { String(format: "%02x", $0) }.joined(),
                       "6b04c8dd65af6b73eb4279472ed1580b29102d6496a377340e80a40cdb3b22c9")
        return WPEParityProgramAssets(sources: [.directory(root)])
    }

    private func hash(_ pixels: [UInt8]) -> String {
        SHA256.hash(data: Data(pixels)).map { String(format: "%02x", $0) }.joined()
    }

    private func assertError(_ expected: WPEParityTextPreparationError, _ body: () throws -> Void,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) {
            XCTAssertEqual($0 as? WPEParityTextPreparationError, expected, file: file, line: line)
        }
    }
}
