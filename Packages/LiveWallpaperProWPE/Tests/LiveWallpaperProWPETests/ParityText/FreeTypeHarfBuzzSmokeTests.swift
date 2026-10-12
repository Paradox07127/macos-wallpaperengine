import CFreeType
import CHarfBuzz
import Foundation
import XCTest

final class FreeTypeHarfBuzzSmokeTests: XCTestCase {
    private static let fontPath =
        "/Users/example/Library/Application Support/Steam/steamapps/common/wallpaper_engine/assets/fonts/NotoSans-Regular.ttf"

    func testVendoredVersions() throws {
        var library: FT_Library?
        XCTAssertEqual(FT_Init_FreeType(&library), 0)
        let lib = try XCTUnwrap(library)
        defer { FT_Done_FreeType(lib) }

        var major: FT_Int = 0
        var minor: FT_Int = 0
        var patch: FT_Int = 0
        FT_Library_Version(lib, &major, &minor, &patch)
        let harfBuzzVersion = String(cString: hb_version_string())
        print("FreeType \(major).\(minor).\(patch), HarfBuzz \(harfBuzzVersion)")
        XCTAssertEqual([major, minor, patch], [2, 14, 3])
        XCTAssertEqual(harfBuzzVersion, "14.2.0")
    }

    func testShapeAndRenderWPEAssetFont() throws {
        guard FileManager.default.fileExists(atPath: Self.fontPath) else {
            throw XCTSkip("Wallpaper Engine assets font not installed at \(Self.fontPath)")
        }
        let fontData = try Data(contentsOf: URL(fileURLWithPath: Self.fontPath))

        var library: FT_Library?
        XCTAssertEqual(FT_Init_FreeType(&library), 0)
        let lib = try XCTUnwrap(library)
        defer { FT_Done_FreeType(lib) }

        // FT_New_Memory_Face borrows the bytes, so they must outlive the face.
        let fontBytes = UnsafeMutableBufferPointer<FT_Byte>.allocate(capacity: fontData.count)
        _ = fontBytes.initialize(from: fontData)
        defer { fontBytes.deallocate() }

        var faceOut: FT_Face?
        XCTAssertEqual(FT_New_Memory_Face(lib, fontBytes.baseAddress, FT_Long(fontBytes.count), 0, &faceOut), 0)
        let face = try XCTUnwrap(faceOut)
        defer { FT_Done_Face(face) }

        XCTAssertEqual(FT_Select_Charmap(face, FT_ENCODING_UNICODE), 0)
        XCTAssertEqual(FT_Set_Char_Size(face, 0, 32 * 64, 300, 300), 0)
        let metrics = face.pointee.size.pointee.metrics
        print("NotoSans 32pt@300dpi ascender \(metrics.ascender >> 6) descender \(metrics.descender >> 6) height \(metrics.height >> 6)")
        XCTAssertGreaterThan(metrics.ascender >> 6, 0)
        XCTAssertLessThan(metrics.descender >> 6, 0)
        XCTAssertGreaterThan(metrics.height >> 6, 0)

        let font = try XCTUnwrap(hb_ft_font_create(face, nil))
        defer { hb_font_destroy(font) }
        hb_ft_font_set_load_flags(font, Int32(FT_LOAD_NO_HINTING))

        let buffer = try XCTUnwrap(hb_buffer_create())
        defer { hb_buffer_destroy(buffer) }
        let text = "Hello, World".unicodeScalars.map(\.value)
        hb_buffer_add_utf32(buffer, text, Int32(text.count), 0, -1)
        hb_buffer_guess_segment_properties(buffer)
        hb_shape(font, buffer, nil, 0)

        var infoCount: UInt32 = 0
        var positionCount: UInt32 = 0
        let infos = try XCTUnwrap(hb_buffer_get_glyph_infos(buffer, &infoCount))
        let positions = try XCTUnwrap(hb_buffer_get_glyph_positions(buffer, &positionCount))
        XCTAssertEqual(infoCount, 12)
        XCTAssertEqual(positionCount, 12)
        let advances = (0 ..< Int(positionCount)).map { positions[$0].x_advance >> 6 }
        print("x_advance>>6 \(advances)")
        for index in 0 ..< Int(positionCount) {
            XCTAssertNotEqual(positions[index].x_advance, 0, "glyph \(index)")
        }

        XCTAssertEqual(FT_Load_Glyph(face, infos[0].codepoint, Int32(FT_LOAD_RENDER | FT_LOAD_COLOR)), 0)
        let bitmap = face.pointee.glyph.pointee.bitmap
        XCTAssertEqual(bitmap.pixel_mode, UInt8(FT_PIXEL_MODE_GRAY.rawValue))
        XCTAssertEqual(bitmap.num_grays, 256)
        let buf = try XCTUnwrap(bitmap.buffer)
        var inkPixels = 0
        for row in 0 ..< Int(bitmap.rows) {
            let line = buf + row * Int(bitmap.pitch)
            for column in 0 ..< Int(bitmap.width) where line[column] != 0 {
                inkPixels += 1
            }
        }
        print("glyph \(infos[0].codepoint) bitmap \(bitmap.width)x\(bitmap.rows) ink pixels \(inkPixels)")
        XCTAssertGreaterThan(inkPixels, 0)
    }
}
