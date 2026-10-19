import Foundation
@testable import LiveWallpaperProWPE
import XCTest

/// Real system-font layout, with no Workshop/engine-assets fixture or replacement font implementation.
final class ParityTextLayoutBoundsTests: XCTestCase {
    private func assets() -> WPEParityProgramAssets {
        WPEParityProgramAssets(sources: [.lookup(URL(fileURLWithPath: "/")) { _ in nil }])
    }

    private func object(spacing: String = "0 0") -> WPEParityTextObject {
        WPEParityTextObject(json: .object([
            "id": .string("text"), "text": .string("AB\nCD"), "font": .string("systemfont_calibri"),
            "pointsize": .number(32), "spacing": .string(spacing),
        ]))
    }

    func testHugeFiniteAuthoredSpacingRejectsInitialBitmapLoad() throws {
        let pipeline = WPEParityTextPipeline(assets: assets(), hdr: false, orthographic: true)
        let oversized = object(spacing: "0 1e30")
        XCTAssertEqual(oversized.spacing.y, 1e30, "finite authored data reaches the actual layout boundary")
        XCTAssertFalse(oversized.usesGlyphEffects)
        XCTAssertThrowsError(try pipeline.add(oversized, effectCount: 0, glyphMode: .bitmap)) {
            XCTAssertEqual($0 as? WPEParityTextPreparationError, .invalidLayoutExtent)
        }
        XCTAssertTrue(pipeline.texts.isEmpty)
        XCTAssertTrue(pipeline.atlases.isEmpty)
    }

    func testRepeatedRejectedBitmapRelayoutKeepsPublishedTextAndThenRecovers() throws {
        let pipeline = WPEParityTextPipeline(assets: assets(), hdr: false, orthographic: true)
        try pipeline.add(object(), effectCount: 0, glyphMode: .bitmap)
        let before = pipeline.texts
        let text = try XCTUnwrap(before["text"])
        _ = try XCTUnwrap(text.layout.mesh, "the real system face must produce a valid baseline")
        let versions = pipeline.atlases.mapValues { $0.mono.contentGeneration }
        for _ in 0 ..< 4 {
            for spacing in ["0 1e30", "1e30 0", "0 -1e30"] {
                XCTAssertThrowsError(try pipeline.prepareRelayouts([.init(object(spacing: spacing))])) {
                    XCTAssertEqual($0 as? WPEParityTextPreparationError, .invalidLayoutExtent)
                }
                XCTAssertEqual(pipeline.texts, before)
                XCTAssertEqual(pipeline.atlases.mapValues { $0.mono.contentGeneration }, versions)
            }
        }
        let changed = object(spacing: "2 12")
        let prepared = try XCTUnwrap(pipeline.prepareRelayouts([.init(changed)]))
        _ = try pipeline.accept(prepared)
        XCTAssertEqual(pipeline.texts["text"]?.object.spacing, SIMD2(2, 12))
        let size = try XCTUnwrap(pipeline.texts["text"]?.layout.fboSize)
        XCTAssertTrue(size.x > 0 && size.y > 0 && size.x <= 32768 && size.y <= 32768)
    }

    func testNonfiniteInputsFailForBothBitmapAndFieldLayout() {
        let fonts = WPEParityFontLibrary(assets: assets())
        for mode in [WPEParityTextGlyphMode.bitmap, .distanceField] {
            for value in [Float.nan, .infinity, -.infinity] {
                for key in [\WPEParityTextLayoutInput.pointSize, \.maxWidth] {
                    var input = object().layoutInput(effectCount: 0)
                    input.glyphMode = mode
                    input[keyPath: key] = value
                    XCTAssertThrowsError(try WPEParityTextLayoutEngine.layout(input, fonts: fonts)) {
                        XCTAssertEqual($0 as? WPEParityTextPreparationError, .invalidLayoutExtent)
                    }
                }
                for key in [\WPEParityTextLayoutInput.spacing, \.padding] {
                    var input = object().layoutInput(effectCount: 0)
                    input.glyphMode = mode
                    input[keyPath: key] = SIMD2(value, 0)
                    XCTAssertThrowsError(try WPEParityTextLayoutEngine.layout(input, fonts: fonts)) {
                        XCTAssertEqual($0 as? WPEParityTextPreparationError, .invalidLayoutExtent)
                    }
                }
            }
        }
    }

    func testFinalExtentIsCheckedBeforeIntegerConversion() throws {
        let input = object().layoutInput(effectCount: 0)
        var mesh = WPEParityTextMesh(minX: 0, bottom: 0, maxX: 32, top: 32,
                                     lineHeight: 32, lineCount: 1, pointSize: 32)
        for value in [Float.nan, .infinity, -.infinity, .greatestFiniteMagnitude, Float(Int.max), 32769] {
            mesh.maxX = value
            XCTAssertThrowsError(try WPEParityTextLayoutEngine.fboSize(mesh, input: input)) {
                XCTAssertEqual($0 as? WPEParityTextPreparationError, .invalidLayoutExtent)
            }
        }
        mesh.minX = -.greatestFiniteMagnitude
        mesh.maxX = .greatestFiniteMagnitude
        XCTAssertThrowsError(try WPEParityTextLayoutEngine.fboSize(mesh, input: input))
        mesh.minX = 0
        mesh.maxX = 32768
        XCTAssertEqual(try WPEParityTextLayoutEngine.fboSize(mesh, input: input), SIMD2(32768, 32))
        mesh.maxX = 32768.75
        XCTAssertEqual(try WPEParityTextLayoutEngine.fboSize(mesh, input: input), SIMD2(32768, 32),
                       "the backing extent keeps truncation toward zero")
        mesh.maxX = 0
        mesh.top = 0
        XCTAssertEqual(try WPEParityTextLayoutEngine.fboSize(mesh, input: input), SIMD2(1, 1))
    }
}
