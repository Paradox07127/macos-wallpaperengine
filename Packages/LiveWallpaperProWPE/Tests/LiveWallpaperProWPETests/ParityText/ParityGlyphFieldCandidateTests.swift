import CryptoKit
import CWPESDF
import Foundation
@testable import LiveWallpaperProWPE
import XCTest

/// Candidate wiring/algorithm checks. These expected values are analytic inputs, not Windows tile oracles.
final class ParityGlyphFieldCandidateTests: XCTestCase {
    func testRealQualifiedOutlineUsesExistingFaceSizeAndProducesThreeDistances() throws {
        let root = PackageTestAssets.root
        let font = try Data(contentsOf: root.appendingPathComponent("fonts/NotoSans-Regular.ttf"))
        XCTAssertEqual(SHA256.hash(data: font).map { String(format: "%02x", $0) }.joined(),
                       "6b04c8dd65af6b73eb4279472ed1580b29102d6496a377340e80a40cdb3b22c9")
        let library = WPEParityFontLibrary(assets: WPEParityProgramAssets(sources: [.directory(root)]))
        let face = try XCTUnwrap(library.chain(fontPath: "fonts/NotoSans-Regular.ttf", pointSize: 8).faces.first)
        let field = try XCTUnwrap(face.glyphField(43, captureStages: true))
        XCTAssertEqual(face.pointSize, 8, "bridge must not load an unscaled or forced-size second face")
        XCTAssertEqual(field.yPpem, 33)
        XCTAssertFalse(field.isColor)
        XCTAssertEqual(field.bitmap.pixelMode, .rgba)
        let width = field.bitmap.width, height = field.bitmap.rows
        XCTAssertGreaterThan(width, 24)
        XCTAssertGreaterThan(height, 24)
        XCTAssertEqual(field.beforeCorrection.count, width * height * 3)
        XCTAssertEqual(field.afterCorrection.count, width * height * 3)
        XCTAssertTrue(field.beforeCorrection.allSatisfy(\.isFinite))
        XCTAssertTrue(field.afterCorrection.allSatisfy(\.isFinite))
        XCTAssertTrue(stride(from: 0, to: field.beforeCorrection.count, by: 3).contains {
            field.beforeCorrection[$0] != field.beforeCorrection[$0 + 1]
                || field.beforeCorrection[$0 + 1] != field.beforeCorrection[$0 + 2]
        }, "true RGB distance data must not be a repeated mono bitmap/SDF")
        XCTAssertTrue(stride(from: 3, to: field.bitmap.pixels.count, by: 4).allSatisfy {
            field.bitmap.pixels[$0] == 255
        })
        // Independently check that the field handed to the existing atlas keeps native RGB byte order.
        var atlas = WPEParityGlyphAtlas(format: .rgba8)
        let entry = try XCTUnwrap(atlas.insert(key: 43, bitmap: field.bitmap))
        for row in 0 ..< height {
            let at = ((entry.y0 + row) * atlas.width + entry.x0) * 4
            XCTAssertEqual(Array(atlas.pixels[at ..< at + width * 4]),
                           Array(field.bitmap.pixels[row * width * 4 ..< (row + 1) * width * 4]))
        }
        XCTAssertNotNil(face.rasterize(43), "candidate must leave the existing face usable by ordinary text")
    }

    func testColorThresholdFloatFieldAndNativeOutputDirection() {
        // Top two alphas are outside; bottom two are inside. Distances at centres are -.5 and +.5.
        // At range 4 that maps to .375/.625, and ×256 truncation gives 96/160, not ×255's 95/159.
        let bytes: [UInt8] = [1, 2, 3, 0, 4, 5, 6, 127, 7, 8, 9, 128, 10, 11, 12, 255]
        let result = color(bytes, width: 2, rows: 2, pitch: 8, row0: 0)
        XCTAssertEqual(result.status, WPE_FIELD_OK)
        XCTAssertEqual(result.rgba, Array(repeating: 96, count: 8) + Array(repeating: 160, count: 8))
        XCTAssertEqual(result.floats, Array(repeating: 0.625, count: 8) + Array(repeating: 0.375, count: 8))
        let reverseRows = Array(bytes.suffix(8)) + Array(bytes.prefix(8))
        let negative = color(reverseRows, width: 2, rows: 2, pitch: -8, row0: 8)
        XCTAssertEqual(negative.status, WPE_FIELD_OK)
        XCTAssertEqual(negative.rgba, result.rgba)
        XCTAssertEqual(negative.floats, result.floats)
    }

    func testColorRejectsOutOfBoundsSignedPitchAndOutputCapacityBeforeWriting() {
        let bytes = [UInt8](repeating: 255, count: 16)
        let invalidPitch = color(bytes, width: 2, rows: 2, pitch: -8, row0: 0)
        XCTAssertEqual(invalidPitch.status, WPE_FIELD_INVALID_INPUT)
        XCTAssertEqual(invalidPitch.rgba, Array(repeating: 17, count: 16))
        let tooShort = color(bytes, width: 2, rows: 2, pitch: 8, row0: 0, outputCapacity: 15)
        XCTAssertEqual(tooShort.status, WPE_FIELD_INVALID_INPUT)
        XCTAssertEqual(tooShort.rgba, Array(repeating: 17, count: 16))
    }

    private func color(_ bytes: [UInt8], width: Int32, rows: Int32, pitch: Int32, row0: Int,
                       outputCapacity: Int = 16) -> (status: WPEFieldStatus, rgba: [UInt8], floats: [Float]) {
        var rgba = [UInt8](repeating: 17, count: 16)
        var floats = [Float](repeating: -7, count: 16)
        var t = WPEFieldTransform(scale_x: 1, scale_y: 1, translate_x: 0.5, translate_y: 0.5,
                                  distance_scale: 0.25, distance_offset: 2)
        let status = bytes.withUnsafeBufferPointer { source in
            rgba.withUnsafeMutableBufferPointer { destination in
                floats.withUnsafeMutableBufferPointer { samples in
                    var b = WPEFieldBGRA(bytes: source.baseAddress, capacity: source.count,
                                         row0_offset: row0, width: width, rows: rows, pitch: pitch,
                                         left: 0, top: 1)
                    var out = WPEFieldOutput(width: 2, height: 2, rgba: destination.baseAddress,
                                             rgba_capacity: outputCapacity, before_correction: nil,
                                             before_capacity: 0, after_correction: samples.baseAddress,
                                             after_capacity: samples.count)
                    return wpe_field_color(&b, &t, &out)
                }
            }
        }
        return (status, rgba, floats)
    }
}
