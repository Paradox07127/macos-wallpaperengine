import CFreeType
import CryptoKit
import CWPESDF
import Foundation
@testable import LiveWallpaperProWPE
import XCTest

/// Root-applied test draft; not compiled or run by S09. Every expected byte comes from qualified Windows raw memory.
final class ParityGlyphFieldOriginalOracleTests: XCTestCase {
    func testRawWindowsOutlineMatchesOriginalStagesAndCell() throws {
        let oracle = try Oracle()
        let header = try oracle.data("outline-header.bin")
        let rawPoints = try oracle.data("outline-points.bin")
        var points = stride(from: 0, to: rawPoints.count, by: 8).map {
            FT_Vector(x: FT_Pos(Int32(bitPattern: u32(rawPoints, $0))),
                      y: FT_Pos(Int32(bitPattern: u32(rawPoints, $0 + 4))))
        }
        var tags = try [UInt8](oracle.data("outline-tags.bin"))
        let ends = try oracle.data("outline-contours.bin")
        var contours = stride(from: 0, to: ends.count, by: 2).map { u16(ends, $0) }
        let t = try oracle.transform()
        var transform = WPEFieldTransform(scale_x: t[0], scale_y: t[1], translate_x: t[2],
                                          translate_y: t[3], distance_scale: t[4], distance_offset: t[5])
        var pre = [Float](repeating: .nan, count: 42 * 47 * 3)
        var post = pre
        var rgba = [UInt8](repeating: 17, count: 42 * 47 * 4)
        // Windows points are signed32 pairs; macOS FT_Pos is widened explicitly, never ABI-reinterpreted.
        let status = points.withUnsafeMutableBufferPointer { p in
            tags.withUnsafeMutableBufferPointer { tags in
                contours.withUnsafeMutableBufferPointer { contours in
                    var outline = FT_Outline(n_contours: u16(header, 0), n_points: u16(header, 2),
                                             points: p.baseAddress, tags: tags.baseAddress, contours: contours.baseAddress,
                                             flags: Int32(bitPattern: u32(header, 32)))
                    return rgba.withUnsafeMutableBufferPointer { pixels in
                        pre.withUnsafeMutableBufferPointer { before in
                            post.withUnsafeMutableBufferPointer { after in
                                var out = WPEFieldOutput(width: 42, height: 47, rgba: pixels.baseAddress,
                                                         rgba_capacity: pixels.count, before_correction: before.baseAddress,
                                                         before_capacity: before.count, after_correction: after.baseAddress, after_capacity: after.count)
                                return wpe_field_outline(&outline, &transform, &out)
                            }
                        }
                    }
                }
            }
        }
        XCTAssertEqual(status, WPE_FIELD_OK)
        try compareAndDump(label: "raw-core", pre: pre, post: post, rgba: rgba, oracle: oracle)
    }

    func testExistingFontFaceMatchesOriginalStagesAndCell() throws {
        let oracle = try Oracle()
        let library = WPEParityFontLibrary(assets: WPEParityProgramAssets(sources: [.directory(oracle.root)]))
        let face = try XCTUnwrap(library.chain(fontPath: "NotoSans-Regular.ttf", pointSize: 8).faces.first)
        let field = try XCTUnwrap(face.glyphField(43, captureStages: true))
        XCTAssertEqual(face.pointSize, 8)
        XCTAssertEqual(field.yPpem, 33)
        XCTAssertFalse(field.isColor)
        XCTAssertEqual(field.bitmap.width, 42)
        XCTAssertEqual(field.bitmap.rows, 47)
        XCTAssertEqual(field.bitmap.pixelMode, .rgba)
        XCTAssertEqual([field.box.xMin, field.box.yMin, field.box.xMax, field.box.yMax], [3, 0, 22, 24])
        let t = field.transform
        XCTAssertEqual([t.scaleX, t.scaleY, t.translateX, t.translateY, t.distanceScale, t.distanceOffset].map(\.bitPattern),
                       try oracle.transform().map(\.bitPattern))
        try compareAndDump(label: "font-face", pre: field.beforeCorrection, post: field.afterCorrection,
                           rgba: field.bitmap.pixels, oracle: oracle)
        XCTAssertNotNil(face.rasterize(43), "existing serial face must remain usable")
    }

    private func compareAndDump(label: String, pre: [Float], post: [Float], rgba: [UInt8], oracle: Oracle) throws {
        let expectedPre = try oracle.data("pre.bin")
        let expectedPost = try oracle.data("post.bin")
        let expectedRGBA = try oracle.data("rgba-cell.bin")
        let preBytes = floatBytes(pre), postBytes = floatBytes(post), rgbaBytes = Data(rgba)
        if let base = ProcessInfo.processInfo.environment["LOOMSCREEN_WPE_GLYPH_CANDIDATE_OUT"] {
            let directory = URL(fileURLWithPath: base).appendingPathComponent(label, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            for (name, data) in [("pre.f32le", preBytes), ("post.f32le", postBytes), ("rgba.bin", rgbaBytes)] {
                try data.write(to: directory.appendingPathComponent(name), options: .withoutOverwriting)
            }
        }
        // Bit-exact fields are a diagnostic acceptance gate; failures retain actual dumps for ULP/byte diagnosis.
        assertBytes(preBytes, expectedPre, label: label + " original pre float32")
        assertBytes(postBytes, expectedPost, label: label + " original post float32")
        assertBytes(rgbaBytes, expectedRGBA, label: label + " original RGBA cell")
    }

    private func assertBytes(_ actual: Data, _ expected: Data, label: String) {
        XCTAssertEqual(actual.count, expected.count, label + " length")
        let mismatches = zip(actual, expected).enumerated().compactMap { $0.element.0 == $0.element.1 ? nil : $0.offset }
        XCTAssertEqual(mismatches.count, 0, label + " differing bytes; first offsets " + String(describing: mismatches.prefix(8)))
    }

    private func floatBytes(_ values: [Float]) -> Data {
        let bits = values.map(\.bitPattern.littleEndian)
        return bits.withUnsafeBytes { Data($0) }
    }

    private struct Oracle {
        let root: URL
        private let files: [String: String]
        init() throws {
            guard let path = ProcessInfo.processInfo.environment["LOOMSCREEN_WPE_GLYPH_ORACLE_DIR"] else {
                throw NSError(domain: "OriginalGlyphOracle", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Root must supply the pinned original oracle directory; no skip/fallback"])
            }
            root = URL(fileURLWithPath: path, isDirectory: true)
            let manifest = try Data(contentsOf: root.appendingPathComponent("manifest.json"))
            guard Self.sha(manifest) == "ac47bffbf998d8ac6fb3bec69f2564b6f7578bb13509ffc575a759746a50da1f",
                  let body = try JSONSerialization.jsonObject(with: manifest) as? [String: Any],
                  let entries = body["files"] as? [[String: Any]] else {
                throw NSError(domain: "OriginalGlyphOracle", code: 2)
            }
            var pins: [String: String] = [:]
            for entry in entries {
                guard let name = entry["path"] as? String, let pin = entry["sha256"] as? String,
                      let size = entry["bytes"] as? Int, !name.contains("/"), pins[name] == nil else {
                    throw NSError(domain: "OriginalGlyphOracle", code: 3)
                }
                let bytes = try Data(contentsOf: root.appendingPathComponent(name))
                guard bytes.count == size, Self.sha(bytes) == pin else { throw NSError(domain: "OriginalGlyphOracle", code: 4) }
                pins[name] = pin
            }
            files = pins
        }

        func data(_ name: String) throws -> Data {
            let bytes = try Data(contentsOf: root.appendingPathComponent(name))
            guard let pin = files[name], Self.sha(bytes) == pin else { throw NSError(domain: "OriginalGlyphOracle", code: 5) }
            return bytes
        }

        func transform() throws -> [Double] {
            let bytes = try data("transform.bin")
            return stride(from: 0, to: bytes.count, by: 8).map { Double(bitPattern: u64(bytes, $0)) }
        }

        private static func sha(_ data: Data) -> String {
            SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
    }
}

private func u16(_ data: Data, _ at: Int) -> UInt16 {
    UInt16(data[at]) | UInt16(data[at + 1]) << 8
}

private func u32(_ data: Data, _ at: Int) -> UInt32 {
    (0 ..< 4).reduce(0) { $0 | UInt32(data[at + $1]) << ($1 * 8) }
}

private func u64(_ data: Data, _ at: Int) -> UInt64 {
    (0 ..< 8).reduce(0) { $0 | UInt64(data[at + $1]) << ($1 * 8) }
}
