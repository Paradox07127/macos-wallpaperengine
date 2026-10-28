import CFreeType
import CHarfBuzz
import Foundation
import XCTest

final class FreeTypeHarfBuzzSmokeTests: XCTestCase {
    private static let fontPath = PackageTestAssets.fonts.appendingPathComponent("NotoSans-Regular.ttf").path

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

    func testVariableDesignCoordinatesZeroFillExcessValues() throws {
        let fontPath = "/System/Library/Fonts/SFNS.ttf"
        guard FileManager.default.fileExists(atPath: fontPath) else {
            throw XCTSkip("The host's variable system font is unavailable")
        }
        var library: FT_Library?
        XCTAssertEqual(FT_Init_FreeType(&library), 0)
        let lib = try XCTUnwrap(library)
        defer { FT_Done_FreeType(lib) }
        var faceOut: FT_Face?
        XCTAssertEqual(FT_New_Face(lib, fontPath, 0, &faceOut), 0)
        let face = try XCTUnwrap(faceOut)
        defer { FT_Done_Face(face) }
        var variationOut: UnsafeMutablePointer<FT_MM_Var>?
        XCTAssertEqual(FT_Get_MM_Var(face, &variationOut), 0)
        let variation = try XCTUnwrap(variationOut)
        defer { FT_Done_MM_Var(lib, variation) }
        let axes = Int(variation.pointee.num_axis)
        XCTAssertGreaterThan(axes, 0)
        let axis = try XCTUnwrap(variation.pointee.axis)

        for useMaximum in [false, true] {
            var expected = (0 ..< axes).map { useMaximum ? axis[$0].maximum : axis[$0].def }
            XCTAssertEqual(FT_Set_Var_Design_Coordinates(face, UInt32(axes), &expected), 0)
            let sentinel: FT_Fixed = 0x1234_5678
            var exact = [FT_Fixed](repeating: sentinel, count: axes + 1)
            XCTAssertEqual(FT_Get_Var_Design_Coordinates(face, UInt32(axes), &exact), 0)
            XCTAssertEqual(Array(exact.prefix(axes)), expected)
            XCTAssertEqual(exact[axes], sentinel)

            let requested = axes + 1024
            var excess = [FT_Fixed](repeating: sentinel, count: requested + 1)
            XCTAssertEqual(FT_Get_Var_Design_Coordinates(face, UInt32(requested), &excess), 0)
            XCTAssertEqual(Array(excess.prefix(axes)), expected)
            // FT_Get_Var_Design_Coordinates documents zero for every excess coordinate.
            XCTAssertEqual(Array(excess[axes ..< requested]), [FT_Fixed](repeating: 0, count: requested - axes))
            XCTAssertEqual(excess[requested], sentinel)
        }
    }

    func testColorGlyphCallbackKeepsItsOwnUserData() throws {
        var colorToken: UInt8 = 1
        var clipToken: UInt8 = 2
        try withUnsafeMutablePointer(to: &colorToken) { colorData in
            try withUnsafeMutablePointer(to: &clipToken) { clipData in
                for installsClip in [false, true] {
                    let funcs = try XCTUnwrap(hb_paint_funcs_create())
                    defer { hb_paint_funcs_destroy(funcs) }
                    hb_paint_funcs_set_color_glyph_func(funcs, { _, paintData, glyph, _, userData in
                        paintData == userData && glyph == 42 ? 1 : 0
                    }, colorData, nil)
                    if installsClip {
                        hb_paint_funcs_set_push_clip_glyph_func(funcs, { _, _, _, _, _ in }, clipData, nil)
                    }
                    XCTAssertEqual(hb_paint_color_glyph(funcs, colorData, 42, hb_font_get_empty()), 1)
                }
            }
        }
    }

    func testCPALVersionOnePaletteTypesUse32BitWireValues() throws {
        _ = try Data(contentsOf: URL(fileURLWithPath: Self.fontPath))
        let sourceBlob = try XCTUnwrap(hb_blob_create_from_file_or_fail(Self.fontPath))
        defer { hb_blob_destroy(sourceBlob) }
        let source = try XCTUnwrap(hb_face_create(sourceBlob, 0))
        defer { hb_face_destroy(source) }
        var tableCount = hb_face_get_table_tags(source, 0, nil, nil)
        var tags = [hb_tag_t](repeating: 0, count: Int(tableCount))
        tags.withUnsafeMutableBufferPointer {
            _ = hb_face_get_table_tags(source, 0, &tableCount, $0.baseAddress)
        }
        // CPAL v1: one color per palette, three uint32 palette types [1, 2, 3].
        let cpal: [UInt8] = [
            0, 1, 0, 1, 0, 3, 0, 3, 0, 0, 0, 30,
            0, 0, 0, 1, 0, 2,
            0, 0, 0, 42, 0, 0, 0, 0, 0, 0, 0, 0,
            0x11, 0x22, 0x33, 0xFF, 0x44, 0x55, 0x66, 0xFF, 0x77, 0x88, 0x99, 0xFF,
            0, 0, 0, 1, 0, 0, 0, 2, 0, 0, 0, 3,
        ]
        var library: FT_Library?
        XCTAssertEqual(FT_Init_FreeType(&library), 0)
        let lib = try XCTUnwrap(library)
        defer { FT_Done_FreeType(lib) }

        for truncated in [false, true] {
            let builder = try XCTUnwrap(hb_face_builder_create())
            defer { hb_face_destroy(builder) }
            for tag in tags {
                let table = try XCTUnwrap(hb_face_reference_table(source, tag))
                defer { hb_blob_destroy(table) }
                XCTAssertNotEqual(hb_face_builder_add_table(builder, tag, table), 0)
            }
            let payload = truncated ? Array(cpal.dropLast()) : cpal
            let paletteBlob = try payload.withUnsafeBytes { bytes in
                try XCTUnwrap(hb_blob_create(
                    bytes.baseAddress?.assumingMemoryBound(to: CChar.self),
                    UInt32(bytes.count), HB_MEMORY_MODE_DUPLICATE, nil, nil
                ))
            }
            defer { hb_blob_destroy(paletteBlob) }
            XCTAssertNotEqual(hb_face_builder_add_table(builder, 0x4350_414C, paletteBlob), 0)
            let sfnt = try XCTUnwrap(hb_face_reference_blob(builder))
            defer { hb_blob_destroy(sfnt) }
            var byteCount: UInt32 = 0
            let bytes = try XCTUnwrap(hb_blob_get_data(sfnt, &byteCount))
            var faceOut: FT_Face?
            XCTAssertEqual(FT_New_Memory_Face(
                lib, UnsafeRawPointer(bytes).assumingMemoryBound(to: FT_Byte.self), FT_Long(byteCount), 0, &faceOut
            ), 0)
            let face = try XCTUnwrap(faceOut)
            defer { FT_Done_Face(face) }
            var data = FT_Palette_Data()
            XCTAssertEqual(FT_Palette_Data_Get(face, &data), 0)
            if truncated {
                XCTAssertNil(data.palette_flags, "Reject a palette-types array missing its last byte")
                continue
            }
            XCTAssertEqual(data.num_palettes, 3)
            XCTAssertEqual(data.num_palette_entries, 1)
            let flags = try XCTUnwrap(data.palette_flags)
            XCTAssertEqual(Array(UnsafeBufferPointer(start: flags, count: 3)), [1, 2, 3])
            for (index, blue) in [UInt8(0x11), 0x44, 0x77].enumerated() {
                var colors: UnsafeMutablePointer<FT_Color>?
                XCTAssertEqual(FT_Palette_Select(face, FT_UShort(index), &colors), 0)
                let color = try XCTUnwrap(colors).pointee
                XCTAssertEqual([color.blue, color.green, color.red, color.alpha], [blue, blue + 0x11, blue + 0x22, 0xFF])
            }
        }
    }

    func testShapeAndRenderWPEAssetFont() throws {
        _ = try Data(contentsOf: URL(fileURLWithPath: Self.fontPath))
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
