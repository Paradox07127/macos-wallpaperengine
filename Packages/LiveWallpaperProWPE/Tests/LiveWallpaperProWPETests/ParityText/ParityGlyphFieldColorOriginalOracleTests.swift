import CFreeType
import CryptoKit
import CWPESDF
import Foundation
@testable import LiveWallpaperProWPE
import XCTest

/// Expected primary and companion bytes are qualified same-call Windows COLOR originals; no generated golden.
final class ParityGlyphFieldColorOriginalOracleTests: XCTestCase {
    func testRawWindowsColorMatchesOriginalFieldAndCell() throws {
        try compareRaw(Oracle(scale: 1))
    }

    func testRawWindowsColorScaleTwoMatchesOriginalFieldAndCell() throws {
        try compareRaw(Oracle(scale: 2))
    }

    private func compareRaw(_ oracle: Oracle) throws {
        let header = try oracle.data("color-header.bin")
        let source = try oracle.data("bgra-span.bin")
        let pitch = Int32(bitPattern: colorU32(header, 0x30))
        let rows = Int32(bitPattern: colorU32(header, 0x28))
        let width = Int32(bitPattern: colorU32(header, 0x2C))
        let left = Int32(bitPattern: colorU32(header, 0x20))
        let top = Int32(bitPattern: colorU32(header, 0x24))
        XCTAssertEqual(Int(width), oracle.sourceWidth); XCTAssertEqual(Int(rows), oracle.sourceRows)
        XCTAssertEqual(Int(pitch), oracle.sourcePitch)
        XCTAssertEqual(header[0x42], 7)
        let t = try oracle.transform()
        var transform = WPEFieldTransform(scale_x: t[0], scale_y: t[1], translate_x: t[2], translate_y: t[3],
                                          distance_scale: t[4], distance_offset: t[5])
        var post = [Float](repeating: .nan, count: oracle.width * oracle.height * 4)
        var rgba = [UInt8](repeating: 17, count: post.count)
        var companion = [UInt8](repeating: 17, count: oracle.width * oracle.height * oracle.scale * oracle.scale * 4)
        let (status, companionStatus) = source.withUnsafeBytes { bytes in
            var bitmap = WPEFieldBGRA(bytes: bytes.baseAddress!.assumingMemoryBound(to: UInt8.self),
                                      capacity: bytes.count, row0_offset: pitch < 0 ? Int(rows - 1) * -Int(pitch) : 0,
                                      width: width, rows: rows, pitch: pitch, left: left, top: top)
            let primaryStatus = rgba.withUnsafeMutableBufferPointer { pixels in
                post.withUnsafeMutableBufferPointer { after in
                    var output = WPEFieldOutput(width: Int32(oracle.width), height: Int32(oracle.height),
                                                rgba: pixels.baseAddress, rgba_capacity: pixels.count,
                                                before_correction: nil, before_capacity: 0, after_correction: after.baseAddress, after_capacity: after.count)
                    return wpe_field_color(&bitmap, &transform, &output)
                }
            }
            let companionStatus = companion.withUnsafeMutableBufferPointer { pixels in
                var output = WPEFieldOutput(width: Int32(oracle.width * oracle.scale), height: Int32(oracle.height * oracle.scale),
                                            rgba: pixels.baseAddress, rgba_capacity: pixels.count,
                                            before_correction: nil, before_capacity: 0, after_correction: nil, after_capacity: 0)
                // Keep the original scale-one ABI under its existing original-byte guard.
                return oracle.scale == 1 ? wpe_field_color_companion_scale_one(&bitmap, &transform, &output)
                    : wpe_field_color_companion(&bitmap, &transform, Int32(oracle.scale), &output)
            }
            return (primaryStatus, companionStatus)
        }
        XCTAssertEqual(status, WPE_FIELD_OK)
        XCTAssertEqual(companionStatus, WPE_FIELD_OK)
        try compareAndDump(label: "raw-color-core", post: post, rgba: rgba, companion: companion, sourceBGRA: source, oracle: oracle)
    }

    func testExistingFontFaceColorMatchesOriginalBitmapFieldAndCell() throws {
        try compareFace(Oracle(scale: 1))
    }

    func testExistingFontFaceColorScaleTwoMatchesOriginalBitmapFieldAndCell() throws {
        try compareFace(Oracle(scale: 2))
    }

    private func compareFace(_ oracle: Oracle) throws {
        let library = WPEParityFontLibrary(assets: WPEParityProgramAssets(sources: [.directory(oracle.root)]))
        let face = try XCTUnwrap(library.chain(fontPath: "TwemojiMozilla.ttf", pointSize: oracle.pointSize).faces.first)
        let source = try XCTUnwrap(face.rasterize(166))
        XCTAssertEqual(source.width, oracle.sourceWidth); XCTAssertEqual(source.rows, oracle.sourceRows)
        XCTAssertEqual(source.pixelMode, .bgra)
        try assertBytes(Data(source.pixels), oracle.data("bgra-packed.bin"), label: "existing FontFace original BGRA")
        let pair = try XCTUnwrap(face.colorGlyphField(166, companionScale: oracle.scale, captureStages: true))
        let field = pair.primary
        XCTAssertEqual(pair.companionScale, oracle.scale)
        XCTAssertEqual(pair.companion.width, field.bitmap.width * oracle.scale)
        XCTAssertEqual(pair.companion.rows, field.bitmap.rows * oracle.scale)
        XCTAssertEqual(pair.companion.pixelMode, .rgba)
        XCTAssertEqual(face.pointSize, oracle.pointSize)
        XCTAssertEqual(field.yPpem, oracle.ppem); XCTAssertTrue(field.isColor)
        XCTAssertEqual(field.bitmap.width, oracle.width); XCTAssertEqual(field.bitmap.rows, oracle.height)
        XCTAssertEqual(field.bitmap.pixelMode, .rgba); XCTAssertTrue(field.beforeCorrection.isEmpty)
        XCTAssertEqual([field.box.xMin, field.box.yMin, field.box.xMax, field.box.yMax], oracle.cbox)
        let t = field.transform
        XCTAssertEqual([t.scaleX, t.scaleY, t.translateX, t.translateY, t.distanceScale, t.distanceOffset].map(\.bitPattern),
                       try oracle.transform().map(\.bitPattern))
        try compareAndDump(label: "font-face-color", post: field.afterCorrection, rgba: field.bitmap.pixels,
                           companion: pair.companion.pixels, sourceBGRA: Data(source.pixels), oracle: oracle)
        XCTAssertNil(face.colorGlyphField(166, companionScale: 3), "unqualified scales must not silently select a group")
        XCTAssertNotNil(face.rasterize(166), "existing serial face remains usable")
    }

    private func compareAndDump(label: String, post: [Float], rgba: [UInt8], companion: [UInt8], sourceBGRA: Data, oracle: Oracle) throws {
        let bits = post.map(\.bitPattern.littleEndian)
        let postBytes = bits.withUnsafeBytes { Data($0) }, rgbaBytes = Data(rgba)
        if let base = ProcessInfo.processInfo.environment[oracle.outputEnvironment] {
            let directory = URL(fileURLWithPath: base).appendingPathComponent(label, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            for (name, data) in [("post.f32le", postBytes), ("rgba.bin", rgbaBytes), ("source-bgra.bin", sourceBGRA), ("companion.bin", Data(companion))] {
                try data.write(to: directory.appendingPathComponent(name), options: .withoutOverwriting)
            }
        }
        try assertBytes(postBytes, oracle.data("colorpost.bin"), label: label + " original float4")
        try assertBytes(rgbaBytes, oracle.data("rgba-cell.bin"), label: label + " original RGBA cell")
        try assertBytes(Data(companion), oracle.data("companion-cell.bin"), label: label + " original companion RGBA cell")
    }

    private func assertBytes(_ actual: Data, _ expected: Data, label: String) {
        XCTAssertEqual(actual.count, expected.count, label + " length")
        let mismatches = zip(actual, expected).enumerated().compactMap { $0.element.0 == $0.element.1 ? nil : $0.offset }
        XCTAssertEqual(mismatches.count, 0, label + " differing bytes; first offsets " + String(describing: mismatches.prefix(8)))
    }

    private struct Oracle {
        let root: URL
        let scale: Int
        let pointSize: Float
        let ppem: Int
        let width: Int, height: Int
        let sourceWidth: Int, sourceRows: Int, sourcePitch: Int
        let cbox: [Int32]
        let outputEnvironment: String
        private let files: [String: String]
        init(scale: Int) throws {
            let environment: String, manifestSHA: String
            if scale == 1 {
                environment = "LOOMSCREEN_WPE_COLOR_ORACLE_DIR"
                outputEnvironment = "LOOMSCREEN_WPE_COLOR_CANDIDATE_OUT"
                manifestSHA = "3865f6694de4f06de499106f12eb614bea3bfc9562eeebcb0b9ade024cb451fc"
            } else {
                precondition(scale == 2)
                environment = "LOOMSCREEN_WPE_COLOR_SCALE2_ORACLE_DIR"
                outputEnvironment = "LOOMSCREEN_WPE_COLOR_SCALE2_CANDIDATE_OUT"
                manifestSHA = "b343ac055b6c45787327427a4fddd506e332ff06be08be8fd8919e01c850c332"
            }
            guard let path = ProcessInfo.processInfo.environment[environment] else {
                throw NSError(domain: "OriginalColorGlyphOracle", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Root must supply the pinned original oracle directory; no skip/fallback"])
            }
            root = URL(fileURLWithPath: path, isDirectory: true)
            let manifest = try Data(contentsOf: root.appendingPathComponent("manifest.json"))
            guard Self.sha(manifest) == manifestSHA,
                  let body = try JSONSerialization.jsonObject(with: manifest) as? [String: Any],
                  body["companionScale"] as? Int == scale,
                  let pointSize = body["pointSize"] as? Double, let ppem = body["ppem"] as? Int,
                  let width = body["width"] as? Int, let height = body["height"] as? Int,
                  let sourceWidth = body["sourceWidth"] as? Int, let sourceRows = body["sourceRows"] as? Int,
                  let sourcePitch = body["sourcePitch"] as? Int, let cbox = body["cbox"] as? [Int],
                  let entries = body["files"] as? [[String: Any]] else {
                throw NSError(domain: "OriginalColorGlyphOracle", code: 2)
            }
            self.scale = scale
            self.pointSize = Float(pointSize)
            self.ppem = ppem
            self.width = width; self.height = height
            self.sourceWidth = sourceWidth; self.sourceRows = sourceRows; self.sourcePitch = sourcePitch
            self.cbox = cbox.map { Int32($0) }
            var pins: [String: String] = [:]
            for entry in entries {
                guard let name = entry["path"] as? String, let pin = entry["sha256"] as? String,
                      let size = entry["bytes"] as? Int, !name.contains("/"), pins[name] == nil else {
                    throw NSError(domain: "OriginalColorGlyphOracle", code: 3)
                }
                let bytes = try Data(contentsOf: root.appendingPathComponent(name))
                guard bytes.count == size, Self.sha(bytes) == pin else { throw NSError(domain: "OriginalColorGlyphOracle", code: 4) }
                pins[name] = pin
            }
            files = pins
        }

        func data(_ name: String) throws -> Data {
            let bytes = try Data(contentsOf: root.appendingPathComponent(name))
            guard let pin = files[name], Self.sha(bytes) == pin else { throw NSError(domain: "OriginalColorGlyphOracle", code: 5) }
            return bytes
        }

        func transform() throws -> [Double] {
            if scale == 1 {
                let bytes = try data("numeric-transform.bin")
                return stride(from: 0, to: bytes.count, by: 8).map { Double(bitPattern: colorU64(bytes, $0)) }
            }
            let scaling = try data("color-scale.bin"), translation = try data("color-translate.bin")
            let range = try Double(Float(bitPattern: colorU32(data("range-register.bin"), 0)))
            // Original caller's six-double descriptor; range bits come from the complete native XMM views.
            return [Double(bitPattern: colorU64(scaling, 0)), Double(bitPattern: colorU64(scaling, 8)),
                    Double(bitPattern: colorU64(translation, 0)), Double(bitPattern: colorU64(translation, 8)),
                    1 / range, range * 0.5]
        }

        private static func sha(_ data: Data) -> String {
            SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
    }
}

private func colorU32(_ data: Data, _ at: Int) -> UInt32 {
    (0 ..< 4).reduce(0) { $0 | UInt32(data[at + $1]) << ($1 * 8) }
}

private func colorU64(_ data: Data, _ at: Int) -> UInt64 {
    (0 ..< 8).reduce(0) { $0 | UInt64(data[at + $1]) << ($1 * 8) }
}
