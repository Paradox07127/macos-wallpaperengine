import CFreeType
import CWPESDF
import CryptoKit
import Foundation
@testable import LiveWallpaperProWPE
import XCTest

/// Root-applied draft. S09 did not compile/run it. Expected bytes are qualified Windows COLOR originals.
final class ParityGlyphFieldColorOriginalOracleTests: XCTestCase {
    func testRawWindowsColorMatchesOriginalFieldAndCell() throws {
        let oracle = try Oracle()
        let header = try oracle.data("color-header.bin")
        let source = try oracle.data("bgra-span.bin")
        let pitch = Int32(bitPattern: colorU32(header, 0x30))
        let rows = Int32(bitPattern: colorU32(header, 0x28))
        let width = Int32(bitPattern: colorU32(header, 0x2c))
        let left = Int32(bitPattern: colorU32(header, 0x20))
        let top = Int32(bitPattern: colorU32(header, 0x24))
        XCTAssertEqual(width, 32); XCTAssertEqual(rows, 30); XCTAssertEqual(pitch, 128)
        XCTAssertEqual(header[0x42], 7)
        let t = try oracle.transform()
        var transform = WPEFieldTransform(scale_x: t[0], scale_y: t[1], translate_x: t[2], translate_y: t[3],
                                          distance_scale: t[4], distance_offset: t[5])
        var post = [Float](repeating: .nan, count: 56 * 54 * 4)
        var rgba = [UInt8](repeating: 17, count: 56 * 54 * 4)
        let status = source.withUnsafeBytes { bytes in
            var bitmap = WPEFieldBGRA(bytes: bytes.baseAddress!.assumingMemoryBound(to: UInt8.self),
                capacity: bytes.count, row0_offset: pitch < 0 ? Int(rows - 1) * -Int(pitch) : 0,
                width: width, rows: rows, pitch: pitch, left: left, top: top)
            return rgba.withUnsafeMutableBufferPointer { pixels in
                post.withUnsafeMutableBufferPointer { after in
                    var output = WPEFieldOutput(width: 56, height: 54, rgba: pixels.baseAddress, rgba_capacity: pixels.count,
                        before_correction: nil, before_capacity: 0, after_correction: after.baseAddress, after_capacity: after.count)
                    return wpe_field_color(&bitmap, &transform, &output)
                }
            }
        }
        XCTAssertEqual(status, WPE_FIELD_OK)
        try compareAndDump(label: "raw-color-core", post: post, rgba: rgba, sourceBGRA: source, oracle: oracle)
    }

    func testExistingFontFaceColorMatchesOriginalBitmapFieldAndCell() throws {
        let oracle = try Oracle()
        let library = WPEParityFontLibrary(assets: WPEParityProgramAssets(sources: [.directory(oracle.root)]))
        let face = try XCTUnwrap(library.chain(fontPath: "TwemojiMozilla.ttf", pointSize: 7.68).faces.first)
        let source = try XCTUnwrap(face.rasterize(166))
        XCTAssertEqual(source.width, 32); XCTAssertEqual(source.rows, 30); XCTAssertEqual(source.pixelMode, .bgra)
        assertBytes(Data(source.pixels), try oracle.data("bgra-packed.bin"), label: "existing FontFace original BGRA")
        let field = try XCTUnwrap(face.glyphField(166, captureStages: true))
        XCTAssertEqual(face.pointSize, 7.68)
        XCTAssertEqual(field.yPpem, 32); XCTAssertTrue(field.isColor)
        XCTAssertEqual(field.bitmap.width, 56); XCTAssertEqual(field.bitmap.rows, 54)
        XCTAssertEqual(field.bitmap.pixelMode, .rgba); XCTAssertTrue(field.beforeCorrection.isEmpty)
        XCTAssertEqual([field.box.xMin, field.box.yMin, field.box.xMax, field.box.yMax], [0, -3, 32, 27])
        let t = field.transform
        XCTAssertEqual([t.scaleX, t.scaleY, t.translateX, t.translateY, t.distanceScale, t.distanceOffset].map(\.bitPattern),
                       try oracle.transform().map(\.bitPattern))
        try compareAndDump(label: "font-face-color", post: field.afterCorrection, rgba: field.bitmap.pixels,
                           sourceBGRA: Data(source.pixels), oracle: oracle)
        XCTAssertNotNil(face.rasterize(166), "existing serial face remains usable")
    }

    private func compareAndDump(label: String, post: [Float], rgba: [UInt8], sourceBGRA: Data, oracle: Oracle) throws {
        let bits = post.map { $0.bitPattern.littleEndian }
        let postBytes = bits.withUnsafeBytes { Data($0) }, rgbaBytes = Data(rgba)
        if let base = ProcessInfo.processInfo.environment["LOOMSCREEN_WPE_COLOR_CANDIDATE_OUT"] {
            let directory = URL(fileURLWithPath: base).appendingPathComponent(label, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            for (name, data) in [("post.f32le", postBytes), ("rgba.bin", rgbaBytes), ("source-bgra.bin", sourceBGRA)] {
                try data.write(to: directory.appendingPathComponent(name), options: .withoutOverwriting)
            }
        }
        assertBytes(postBytes, try oracle.data("colorpost.bin"), label: label + " original float4")
        assertBytes(rgbaBytes, try oracle.data("rgba-cell.bin"), label: label + " original RGBA cell")
    }

    private func assertBytes(_ actual: Data, _ expected: Data, label: String) {
        XCTAssertEqual(actual.count, expected.count, label + " length")
        let mismatches = zip(actual, expected).enumerated().compactMap { $0.element.0 == $0.element.1 ? nil : $0.offset }
        XCTAssertEqual(mismatches.count, 0, label + " differing bytes; first offsets " + String(describing: mismatches.prefix(8)))
    }

    private struct Oracle {
        let root: URL
        private let files: [String: String]
        init() throws {
            guard let path = ProcessInfo.processInfo.environment["LOOMSCREEN_WPE_COLOR_ORACLE_DIR"] else {
                throw NSError(domain: "OriginalColorGlyphOracle", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Root must supply the pinned original oracle directory; no skip/fallback"])
            }
            root = URL(fileURLWithPath: path, isDirectory: true)
            let manifest = try Data(contentsOf: root.appendingPathComponent("manifest.json"))
            guard Self.sha(manifest) == "3865f6694de4f06de499106f12eb614bea3bfc9562eeebcb0b9ade024cb451fc",
                  let body = try JSONSerialization.jsonObject(with: manifest) as? [String: Any],
                  let entries = body["files"] as? [[String: Any]] else {
                throw NSError(domain: "OriginalColorGlyphOracle", code: 2)
            }
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
            let bytes = try data("numeric-transform.bin")
            return stride(from: 0, to: bytes.count, by: 8).map { Double(bitPattern: colorU64(bytes, $0)) }
        }
        private static func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    }
}

private func colorU32(_ data: Data, _ at: Int) -> UInt32 { (0 ..< 4).reduce(0) { $0 | UInt32(data[at + $1]) << ($1 * 8) } }
private func colorU64(_ data: Data, _ at: Int) -> UInt64 { (0 ..< 8).reduce(0) { $0 | UInt64(data[at + $1]) << ($1 * 8) } }
