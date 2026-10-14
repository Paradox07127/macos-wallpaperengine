#if !LITE_BUILD && DEBUG
@testable import LiveWallpaper
import LiveWallpaperCore
import LiveWallpaperProWPE
import XCTest

final class WPEParityColorCorrectionPresetTests: XCTestCase {
    func testCanonicalPresetFeedsWPEParamsAndIndependentLUTAmount() throws {
        let correction = try WPEParityColorCorrection(presetSnapshot: [
            "wec_e": .bool(true), "wec_con": .number(100), "wec_brs": .number(25),
            "wec_sa": .number(12.5), "wec_hue": .number(75),
            "wcc_v": .string("Looks/暖色 Grade"), "wcc_amt": .number(25),
        ])
        XCTAssertTrue(correction.adjustsColor)
        XCTAssertTrue(correction.appliesLUT)
        XCTAssertEqual(correction.params[0], 0.25, accuracy: 1e-6)
        XCTAssertEqual(correction.params[1], Float(2).squareRoot(), accuracy: 1e-6)
        XCTAssertEqual(correction.params[2], 0.5, accuracy: 1e-6)
        XCTAssertEqual(correction.params[3], 0.25, accuracy: 1e-6)
        XCTAssertEqual(correction.lut, "Looks/暖色 Grade")
        XCTAssertEqual(correction.lutAmount, 0.25)
    }

    func testMissingEnableFlagDoesNotTurnSlidersOnAndLUTWorksIndependently() throws {
        let sliders = try WPEParityColorCorrection(presetSnapshot: ["wec_brs": .number(25)])
        XCTAssertFalse(sliders.enabled)
        XCTAssertFalse(sliders.drawn)
        let lut = try WPEParityColorCorrection(presetSnapshot: [
            "wec_e": .bool(false), "wcc_v": .string("neutral"), "wcc_amt": .number(50),
        ])
        XCTAssertFalse(lut.adjustsColor)
        XCTAssertTrue(lut.drawn)
        XCTAssertEqual(lut.lutAmount, 0.5)
        let off = try WPEParityColorCorrection(presetSnapshot: ["wcc_v": .string("neutral"), "wcc_amt": .number(0)])
        XCTAssertFalse(off.drawn)
        XCTAssertFalse(try WPEParityColorCorrection(presetSnapshot: [:]).drawn)
    }

    func testPresentUnsupportedValuesFailWithTheirFieldInsteadOfCoercingOrClamping() {
        assertUnsupported(["wec_e": .number(1)], .unsupportedType(field: "wec_e"))
        assertUnsupported(["wcc_v": .bool(true)], .unsupportedType(field: "wcc_v"))
        for field in ["wec_con", "wec_brs", "wec_sa", "wec_hue", "wcc_amt"] {
            assertUnsupported([field: .string("50")], .unsupportedType(field: field))
            assertUnsupported([field: .bool(true)], .unsupportedType(field: field))
            for value in [Double.nan, .infinity, -.infinity, -1, 101, Double.greatestFiniteMagnitude] {
                assertUnsupported([field: .number(value)], .unsupportedNumber(field: field))
            }
        }
    }

    func testUnsafeLUTNamesFailAndSafeNamesStayLiteral() throws {
        for name in ["/absolute", "C:/drive", "file:look", "../outside", "a/../outside", "a/./look",
                     "a//look", "a/", "a\\look", "bad\0look", "bad\nlook"] {
            assertUnsupported(["wcc_v": .string(name)], .unsupportedPath(field: "wcc_v"))
        }
        let literal = "Folder/MixedCase.tex"
        XCTAssertEqual(try WPEParityColorCorrection(presetSnapshot: ["wcc_v": .string(literal)]).lut, literal)
        XCTAssertFalse(try WPEParityColorCorrection(presetSnapshot: ["wcc_v": .string("")]).appliesLUT)
    }

    private func assertUnsupported(_ values: [String: WallpaperEngineProjectPropertyValue],
                                   _ expected: WPEParityColorCorrectionPresetError,
                                   file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try WPEParityColorCorrection(presetSnapshot: values), file: file, line: line) { error in
            XCTAssertEqual(error as? WPEParityColorCorrectionPresetError, expected, file: file, line: line)
        }
    }
}
#endif
