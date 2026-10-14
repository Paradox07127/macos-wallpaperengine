/// One existing font-atlas owner: bitmap keys include point size; distance keys share the font's mono RGBA field.
/// Bitmap COLOR remains scale1. The distance COLOR paired/multiscale consumer is not admitted yet.
public struct WPEParityGlyphAtlasInstance: Sendable {
    public enum Atlas: Hashable, Sendable { case mono, color }

    public let key: String
    public let glyphMode: WPEParityTextGlyphMode
    public var mono: WPEParityGlyphAtlas
    /// Nil until the first BGRA glyph, as WPE creates it.
    public var color: WPEParityGlyphAtlas?

    public init(fontPath: String, pointSize: Float, glyphMode: WPEParityTextGlyphMode = .bitmap) {
        key = Self.key(fontPath: fontPath, pointSize: pointSize, glyphMode: glyphMode)
        self.glyphMode = glyphMode
        mono = WPEParityGlyphAtlas(format: glyphMode == .distanceField ? .rgba8 : .r8)
    }

    public static func key(fontPath: String, pointSize: Float,
                           glyphMode: WPEParityTextGlyphMode = .bitmap) -> String {
        glyphMode == .distanceField ? "\(fontPath)_msdf" : "\(fontPath)_\(Int64(pointSize * 64))"
    }

    public func entry(forKey key: UInt32) -> (atlas: Atlas, entry: WPEParityGlyphAtlasEntry)? {
        if let entry = mono.entry(forKey: key) {
            return (.mono, entry)
        }
        return color?.entry(forKey: key).map { (.color, $0) }
    }

    public mutating func insert(
        key: UInt32,
        bitmap: WPEParityGlyphBitmap
    ) -> (atlas: Atlas, entry: WPEParityGlyphAtlasEntry)? {
        precondition(glyphMode == .bitmap, "Field primary uses its explicit distance insertion")
        if bitmap.pixelMode == .bgra {
            var atlas = color ?? WPEParityGlyphAtlas(format: .rgba8)
            defer { color = atlas }
            return atlas.insert(key: key, bitmap: bitmap).map { (.color, $0) }
        }
        return mono.insert(key: key, bitmap: bitmap).map { (.mono, $0) }
    }

    /// One existing shelf/ref/reset owner. COLOR must later insert a paired primary/companion atomically.
    public mutating func insertDistanceField(key: UInt32, field: WPEParityGlyphField) -> WPEParityGlyphAtlasEntry? {
        precondition(glyphMode == .distanceField && !field.isColor && field.bitmap.pixelMode == .rgba)
        return mono.insert(key: key, bitmap: field.bitmap)
    }
}
