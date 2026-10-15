/// One existing font-atlas owner: bitmap keys include point size; distance keys share the font's mono RGBA field.
/// COLOR groups share each group's one shelf/ref owner, with a paired plane only in field mode.
public struct WPEParityGlyphAtlasInstance: Sendable {
    public enum Atlas: Hashable, Sendable { case mono, color }

    public let key: String
    public let glyphMode: WPEParityTextGlyphMode
    public var mono: WPEParityGlyphAtlas
    public var colorGroups: [Int: WPEParityGlyphAtlas] = [:]
    /// Compatibility access to the one scale1 group, never a second stored owner.
    public var color: WPEParityGlyphAtlas? {
        get { colorGroups[1] }
        set { colorGroups[1] = newValue }
    }

    /// AD400's Float record belongs to this parent, not to an individual fallback FT face.
    private var recordColorScales: [UInt32: Int] = [:]

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

    public func colorScale(recordPointSize: Float) -> Int? {
        recordColorScales[recordPointSize.bitPattern]
    }

    /// ADF30 writes the first actual COLOR CBox scale once per positive finite size record.
    mutating func selectColorScale(recordPointSize: Float, box: WPEParityGlyphBox) throws -> Int {
        guard recordPointSize.isFinite, recordPointSize > 0 else {
            throw WPEParityTextPreparationError.unqualifiedDistanceFieldGroup
        }
        if let scale = colorScale(recordPointSize: recordPointSize) {
            return scale
        }
        let width = Int64(box.xMax) - Int64(box.xMin), height = Int64(box.yMax) - Int64(box.yMin)
        guard width > 0, height > 0 else { throw WPEParityTextPreparationError.zeroAreaDistanceGlyph }
        let scale = glyphMode == .bitmap ? 1 : max(1, Int((max(width, height) + 31) / 32))
        guard scale == 1 || scale == 2 else { throw WPEParityTextPreparationError.unsupportedColorFieldScale(scale) }
        recordColorScales[recordPointSize.bitPattern] = scale
        return scale
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

    public mutating func insertColorField(key: UInt32, field: WPEParityColorGlyphField) -> WPEParityGlyphAtlasEntry? {
        precondition(glyphMode == .distanceField)
        let scale = field.companionScale
        guard scale == 1 || scale == 2 else { return nil }
        var group = colorGroups[scale] ?? WPEParityGlyphAtlas(format: .rgba8, companionScale: scale)
        guard let entry = group.insertColorField(key: key, field: field) else { return nil }
        colorGroups[scale] = group
        return entry
    }
}
