import CFreeType
import CHarfBuzz
import Foundation

/// Owns the FT_Library. Every face holds it, so FT_Done_FreeType runs after the last FT_Done_Face.
final class WPEParityFreeTypeLibrary {
    let handle: FT_Library

    init?() {
        var library: FT_Library?
        guard FT_Init_FreeType(&library) == 0, let library else { return nil }
        handle = library
    }

    deinit {
        FT_Done_FreeType(handle)
    }
}

/// A font file's bytes. FT_New_Memory_Face borrows them, so every face built on them holds this.
final class WPEParityFontBytes {
    let buffer: UnsafeMutableBufferPointer<FT_Byte>

    init(_ data: Data) {
        buffer = .allocate(capacity: data.count)
        _ = buffer.initialize(from: data)
    }

    deinit {
        buffer.deallocate()
    }
}

/// FT_Glyph_Get_CBox(FT_GLYPH_BBOX_PIXELS): integer pixels, y up.
public struct WPEParityGlyphBox: Equatable, Sendable {
    public var xMin: Int32
    public var yMin: Int32
    public var xMax: Int32
    public var yMax: Int32

    public init(xMin: Int32, yMin: Int32, xMax: Int32, yMax: Int32) {
        self.xMin = xMin
        self.yMin = yMin
        self.xMax = xMax
        self.yMax = yMax
    }
}

/// A FreeType face at one point size and 300 dpi with its hb-ft font, as WPE loads it (1401acaf0.c:381-389).
/// FreeType and hb-ft are not thread-safe: one owner uses a face at a time.
public final class WPEParityFontFace {
    struct LayoutGlyph {
        let box: WPEParityGlyphBox
        let isColor: Bool
        let quadPadding: Float
    }

    private struct LayoutKey: Hashable {
        let glyph: UInt32
        let mode: WPEParityTextGlyphMode
    }

    public let pointSize: Float
    public let familyName: String
    public let postScriptName: String?
    /// Cache key of the font file and the face index inside it.
    let source: String
    let faceIndex: Int
    /// Nil for a face FreeType reads from its file.
    let bytes: WPEParityFontBytes?
    let face: FT_Face
    let font: OpaquePointer
    private let library: WPEParityFreeTypeLibrary
    private var boxes: [UInt32: WPEParityGlyphBox?] = [:]
    private var layoutGlyphs: [LayoutKey: LayoutGlyph?] = [:]
    /// Renders layout made that no atlas has taken yet.
    private var unpackedBitmaps: [UInt32: WPEParityGlyphBitmap] = [:]
    /// FT_LOAD_RENDER calls so far.
    private(set) var renders = 0

    var isColorFace: Bool {
        face.pointee.face_flags & FT_Long(FT_FACE_FLAG_COLOR) != 0
    }

    /// Opens face `index` from `bytes`, or from `path` when `bytes` is nil.
    static func open(_ library: WPEParityFreeTypeLibrary, bytes: WPEParityFontBytes?, path: String?,
                     index: Int) -> FT_Face? {
        var face: FT_Face?
        let error: FT_Error
        if let bytes {
            error = FT_New_Memory_Face(library.handle, bytes.buffer.baseAddress, FT_Long(bytes.buffer.count),
                                       FT_Long(index), &face)
        } else if let path {
            error = FT_New_Face(library.handle, path, FT_Long(index), &face)
        } else {
            return nil
        }
        return error == 0 ? face : nil
    }

    init?(library: WPEParityFreeTypeLibrary, bytes: WPEParityFontBytes?, path: String?, source: String, faceIndex: Int,
          pointSize: Float) {
        guard let loaded = Self.open(library, bytes: bytes, path: path, index: faceIndex) else { return nil }
        _ = FT_Select_Charmap(loaded, FT_ENCODING_UNICODE)
        _ = FT_Set_Char_Size(loaded, 0, FT_F26Dot6(Int32(pointSize * 64)), 300, 300)
        guard let font = hb_ft_font_create(loaded, nil) else {
            FT_Done_Face(loaded)
            return nil
        }
        hb_ft_font_set_load_flags(font, Int32(FT_LOAD_NO_HINTING))
        self.library = library
        self.bytes = bytes
        self.source = source
        self.faceIndex = faceIndex
        self.pointSize = pointSize
        face = loaded
        self.font = font
        familyName = loaded.pointee.family_name.map { String(cString: $0) } ?? ""
        postScriptName = FT_Get_Postscript_Name(loaded).map { String(cString: $0) }
    }

    deinit {
        hb_font_destroy(font)
        FT_Done_Face(face)
    }

    /// `size.metrics.ascender >> 6`.
    public var ascender: Int {
        face.pointee.size.pointee.metrics.ascender >> 6
    }

    /// `size.metrics.descender >> 6`.
    public var descender: Int {
        face.pointee.size.pointee.metrics.descender >> 6
    }

    /// `size.metrics.height >> 6`.
    public var height: Int {
        face.pointee.size.pointee.metrics.height >> 6
    }

    func hasCharacter(_ scalar: UInt32) -> Bool {
        FT_Get_Char_Index(face, FT_ULong(scalar)) != 0
    }

    /// FT_Load_Glyph(NO_BITMAP, default hinting) and the outline cbox in pixels, cached per glyph (1401addb0.c).
    public func glyphBox(_ glyph: UInt32) -> WPEParityGlyphBox? {
        if let cached = boxes[glyph] {
            return cached
        }
        let box = loadBox(glyph)
        boxes[glyph] = box
        return box
    }

    /// FT_Load_Glyph(FT_LOAD_RENDER | FT_LOAD_COLOR) with the rows copied out tightly packed; nil when FreeType cannot
    /// render it. The first call after layout met the glyph hands over layout's render.
    public func rasterize(_ glyph: UInt32) -> WPEParityGlyphBitmap? {
        unpackedBitmaps.removeValue(forKey: glyph) ?? render(glyph)
    }

    /// A native field produced in this face's existing serial owner. The explicitly prepared mono planner
    /// consumes it only at a missing atlas entry; ordinary bitmap consumers keep using rasterize.
    /// Captured stages are y-up; bitmap rows are top-first RGBA with no BGRA channel swap.
    public func glyphField(_ glyph: UInt32, captureStages: Bool = false) -> WPEParityGlyphField? {
        let hasColor = face.pointee.face_flags & FT_Long(FT_FACE_FLAG_COLOR) != 0
        let flags = hasColor ? FT_LOAD_RENDER | FT_LOAD_COLOR : FT_LOAD_NO_BITMAP
        guard FT_Load_Glyph(face, glyph, FT_Int32(flags)) == 0 else { return nil }
        let slot = face.pointee.glyph.pointee
        let isColor = UInt32(slot.bitmap.pixel_mode) == FT_PIXEL_MODE_BGRA.rawValue
        let box: WPEParityGlyphBox
        if hasColor {
            guard isColor else { return nil }
            box = WPEParityGlyphBox(xMin: slot.bitmap_left,
                                    yMin: slot.bitmap_top - Int32(slot.bitmap.rows),
                                    xMax: slot.bitmap_left + Int32(slot.bitmap.width), yMax: slot.bitmap_top)
        } else {
            guard slot.format == FT_GLYPH_FORMAT_OUTLINE, let cbox = Self.outlineBox(slot) else { return nil }
            box = cbox
        }
        return WPEParityGlyphFieldProducer.produce(face: face, box: box, isColor: isColor,
                                                   captureStages: captureStages)
    }

    /// CPU preparation for an explicitly qualified scale 1/2 COLOR group, using glyphField's same loaded
    /// slot. It does not choose the parent record's first-glyph scale, admit a material or mutate the atlas.
    /// Other scales remain outside the consumer qualification; nil never means bitmap fallback.
    public func colorGlyphField(_ glyph: UInt32, companionScale: Int,
                                captureStages: Bool = false) -> WPEParityColorGlyphField? {
        guard companionScale == 1 || companionScale == 2 else { return nil }
        return colorGlyphField(glyph, companionScaleForBox: { _ in companionScale }, captureStages: captureStages)
    }

    /// The existing planner selects its parent record after this same slot's actual CBox is available.
    public func colorGlyphField(_ glyph: UInt32, companionScaleForBox: (WPEParityGlyphBox) throws -> Int,
                                captureStages: Bool = false) rethrows -> WPEParityColorGlyphField? {
        guard isColorFace, let primary = glyphField(glyph, captureStages: captureStages) else { return nil }
        let companionScale = try companionScaleForBox(primary.box)
        guard companionScale == 1 || companionScale == 2,
              let companion = WPEParityGlyphFieldProducer.companion(face: face, field: primary,
                                                                    scale: companionScale) else { return nil }
        // Both outputs now own their pixels. Consume layout's temporary BGRA handover without reloading FT.
        unpackedBitmaps.removeValue(forKey: glyph)
        return WPEParityColorGlyphField(primary: primary, companion: companion, companionScale: companionScale)
    }

    private func render(_ glyph: UInt32) -> WPEParityGlyphBitmap? {
        guard let mode = renderedPixelMode(glyph) else { return nil }
        let bitmap = face.pointee.glyph.pointee.bitmap
        let (width, rows) = (Int(bitmap.width), Int(bitmap.rows))
        let rowBytes = width * (mode == .bgra ? 4 : 1)
        var pixels = [UInt8](repeating: 0, count: rowBytes * rows)
        if let buffer = bitmap.buffer {
            for row in 0 ..< rows {
                let source = UnsafeBufferPointer(start: buffer + row * Int(bitmap.pitch), count: rowBytes)
                pixels.replaceSubrange(row * rowBytes ..< (row + 1) * rowBytes, with: source)
            }
        }
        return WPEParityGlyphBitmap(width: width, rows: rows, pixelMode: mode, pixels: pixels)
    }

    /// What layout needs from the atlas: whether the glyph renders at all (WPE drops it otherwise) and in which list.
    func layoutGlyph(_ glyph: UInt32, mode: WPEParityTextGlyphMode = .bitmap) -> LayoutGlyph? {
        let key = LayoutKey(glyph: glyph, mode: mode)
        if let cached = layoutGlyphs[key] {
            return cached
        }
        if mode == .distanceField {
            // Metadata must be qualified for NO_BITMAP, not reused from a rendered bitmap slot. Fields are
            // generated only if the shared atlas lacks the entry; no distance bitmap cache is added here.
            let prepared: LayoutGlyph? = if isColorFace {
                // Preserve actual classification and bearings for the planner's paired COLOR consumer.
                // Do not silently drop a color glyph into the mono list.
                layoutGlyph(glyph, mode: .bitmap)
            } else {
                glyphBox(glyph).map { LayoutGlyph(box: $0, isColor: false, quadPadding: 0) }
            }
            let entry = prepared.map {
                LayoutGlyph(box: $0.box, isColor: $0.isColor,
                            quadPadding: Float(max(face.pointee.size.pointee.metrics.y_ppem, 1)) * 12 / 32)
            }
            layoutGlyphs[key] = entry
            return entry
        }
        let bitmap = render(glyph)
        let entry = bitmap.flatMap { bitmap -> LayoutGlyph? in
            // A bitmap-only colour face has no NO_BITMAP outline. Keep the rendered slot's bearings before
            // glyphBox loads another slot; BGRA quads cover that exact bitmap rather than an outline cbox.
            let slot = face.pointee.glyph.pointee
            let bitmapBox = WPEParityGlyphBox(xMin: slot.bitmap_left,
                                              yMin: slot.bitmap_top - Int32(bitmap.rows),
                                              xMax: slot.bitmap_left + Int32(bitmap.width),
                                              yMax: slot.bitmap_top)
            let box = bitmap.pixelMode == .bgra ? bitmapBox : glyphBox(glyph)
            return box.map { LayoutGlyph(box: $0, isColor: bitmap.pixelMode == .bgra, quadPadding: 0) }
        }
        layoutGlyphs[key] = entry
        if entry != nil {
            unpackedBitmaps[glyph] = bitmap
        }
        return entry
    }

    private func renderedPixelMode(_ glyph: UInt32) -> WPEParityGlyphBitmap.PixelMode? {
        renders += 1
        guard FT_Load_Glyph(face, glyph, FT_Int32(FT_LOAD_RENDER | FT_LOAD_COLOR)) == 0 else { return nil }
        switch UInt32(face.pointee.glyph.pointee.bitmap.pixel_mode) {
        case FT_PIXEL_MODE_GRAY.rawValue: return .gray
        case FT_PIXEL_MODE_BGRA.rawValue: return .bgra
        default: return nil
        }
    }

    /// The module map does not export ftglyph.h, so this is FT_Glyph_Get_CBox's outline path by hand: the control-point
    /// box (FT_Outline_Get_CBox), then FT_PIX_FLOOR / FT_PIX_CEIL and >> 6. NO_BITMAP always yields an outline slot.
    private func loadBox(_ glyph: UInt32) -> WPEParityGlyphBox? {
        guard FT_Load_Glyph(face, glyph, FT_Int32(FT_LOAD_NO_BITMAP)) == 0 else { return nil }
        let slot = face.pointee.glyph.pointee
        guard slot.format == FT_GLYPH_FORMAT_OUTLINE else { return nil }
        return Self.outlineBox(slot)
    }

    private static func outlineBox(_ slot: FT_GlyphSlotRec) -> WPEParityGlyphBox? {
        let points = UnsafeBufferPointer(start: slot.outline.points, count: Int(slot.outline.n_points))
        guard let first = points.first else { return WPEParityGlyphBox(xMin: 0, yMin: 0, xMax: 0, yMax: 0) }
        var box = (xMin: first.x, yMin: first.y, xMax: first.x, yMax: first.y)
        for point in points.dropFirst() {
            box.xMin = min(box.xMin, point.x)
            box.yMin = min(box.yMin, point.y)
            box.xMax = max(box.xMax, point.x)
            box.yMax = max(box.yMax, point.y)
        }
        return WPEParityGlyphBox(
            xMin: Int32((box.xMin & -64) >> 6),
            yMin: Int32((box.yMin & -64) >> 6),
            xMax: Int32(((box.xMax + 63) & -64) >> 6),
            yMax: Int32(((box.yMax + 63) & -64) >> 6)
        )
    }
}
