/// One font file at one point size: a mono R8 atlas and a color RGBA8 atlas (scale 1) for BGRA glyphs.
public struct WPEParityGlyphAtlasInstance: Sendable {
    public enum Atlas: Equatable, Sendable { case mono, color }

    public let key: String
    public var mono = WPEParityGlyphAtlas(format: .r8)
    /// Nil until the first BGRA glyph, as WPE creates it.
    public var color: WPEParityGlyphAtlas?

    public init(fontPath: String, pointSize: Float) {
        key = Self.key(fontPath: fontPath, pointSize: pointSize)
    }

    public static func key(fontPath: String, pointSize: Float) -> String {
        "\(fontPath)_\(Int64(pointSize * 64))"
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
        if bitmap.pixelMode == .bgra {
            var atlas = color ?? WPEParityGlyphAtlas(format: .rgba8)
            defer { color = atlas }
            return atlas.insert(key: key, bitmap: bitmap).map { (.color, $0) }
        }
        return mono.insert(key: key, bitmap: bitmap).map { (.mono, $0) }
    }
}
