/// Lays out text objects and packs their glyphs into one atlas instance per font and point size, shared across text
/// objects as WPE shares them (1401b0410.c:274-349). Holds FreeType objects: one owner at a time.
public final class WPEParityTextPlanner {
    private let fonts: WPEParityFontLibrary
    /// Keyed by `WPEParityGlyphAtlasInstance.key`; whoever uploads them clears their dirty state.
    public var atlases: [String: WPEParityGlyphAtlasInstance] = [:]
    /// The atlas and glyph keys each planned object holds a reference on, so eviction leaves them alone.
    private var held: [String: (atlas: String, mono: [UInt32], color: [UInt32])] = [:]
    /// How often each atlas instance was reset because it was full at 4096.
    public private(set) var resets: [String: Int] = [:]

    public init(assets: WPEParityProgramAssets) {
        fonts = WPEParityFontLibrary(assets: assets)
    }

    /// The layout of `object` without packing its glyphs.
    public func layout(_ object: WPEParityTextObject, effectCount: Int) -> WPEParityTextLayout {
        WPEParityTextLayoutEngine.layout(object.layoutInput(effectCount: effectCount), fonts: fonts)
    }

    /// Takes over `layout`, planned for `objectID` against `atlases`, whose glyph references it already holds.
    public func adopt(objectID: String, layout: WPEParityTextLayout, atlasKey: String) {
        held[objectID] = (atlasKey, layout.mesh?.mono.glyphKeys ?? [], layout.mesh?.color.glyphKeys ?? [])
    }

    /// The layout of `object` with every quad's UVs taken from its atlas instance, and that instance's key. Glyphs
    /// already in the atlas are not rasterised again.
    public func plan(_ object: WPEParityTextObject, effectCount: Int) -> (layout: WPEParityTextLayout, atlasKey: String) {
        var layout = layout(object, effectCount: effectCount)
        let pointSize = layout.mesh?.pointSize ?? WPEParityFontLibrary.clampedPointSize(object.pointSize)
        let key = WPEParityGlyphAtlasInstance.key(fontPath: object.font, pointSize: pointSize)
        guard var mesh = layout.mesh else { return (layout, key) }
        let chain = fonts.chain(fontPath: object.font, pointSize: pointSize)
        var instance = atlases[key] ?? WPEParityGlyphAtlasInstance(fontPath: object.font, pointSize: pointSize)
        let mono = Self.pack(mesh.mono, .mono, chain: chain, into: &instance)
        let color = Self.pack(mesh.color, .color, chain: chain, into: &instance)
        mesh.mono.removeQuads(mono.skipped)
        mesh.color.removeQuads(color.skipped)
        if mono.reset || color.reset {
            resets[key, default: 0] += 1
        }

        if let previous = held[object.id] {
            atlases[previous.atlas]?.mono.release(previous.mono)
            atlases[previous.atlas]?.color?.release(previous.color)
        }
        instance.mono.retain(mesh.mono.glyphKeys)
        instance.color?.retain(mesh.color.glyphKeys)
        held[object.id] = (key, mesh.mono.glyphKeys, mesh.color.glyphKeys)
        atlases[key] = instance

        Self.fillUVs(&mesh.mono, from: instance.mono)
        Self.fillUVs(&mesh.color, from: instance.color)
        layout.mesh = mesh
        return (layout, key)
    }

    /// Re-reads every UV from the atlas as it is now: a later insert may have doubled it and halved the UVs.
    public func refreshUVs(_ layout: inout WPEParityTextLayout, atlasKey: String) {
        guard var mesh = layout.mesh, let instance = atlases[atlasKey] else { return }
        Self.fillUVs(&mesh.mono, from: instance.mono)
        Self.fillUVs(&mesh.color, from: instance.color)
        layout.mesh = mesh
    }

    /// Inserts the glyphs the atlas lacks. On a full atlas the first round resets it and repacks; the second skips
    /// the glyphs that still do not fit (1401b0410.c:933-940, :1095-1214). Returns the skipped quads.
    private static func pack(_ glyphs: WPEParityTextGlyphMesh, _ list: WPEParityGlyphAtlasInstance.Atlas,
                             chain: WPEParityFontChain,
                             into instance: inout WPEParityGlyphAtlasInstance) -> (skipped: Set<Int>, reset: Bool) {
        var skipped: Set<Int> = []
        var reset = false
        for round in 0 ..< 2 {
            skipped = []
            var full = false
            for (quad, key) in glyphs.glyphKeys.enumerated() where instance.entry(forKey: key) == nil {
                let face = Int(key >> 24)
                guard face < chain.faces.count, let bitmap = chain.faces[face].rasterize(key & 0xFFFFFF),
                      (bitmap.pixelMode == .bgra) == (list == .color) else {
                    skipped.insert(quad)
                    continue
                }
                if instance.insert(key: key, bitmap: bitmap) == nil {
                    skipped.insert(quad)
                    if round == 0 {
                        full = true
                        break
                    }
                }
            }
            guard full else { break }
            reset = true
            if list == .mono {
                instance.mono.reset()
            } else {
                instance.color?.reset()
            }
        }
        return (skipped, reset)
    }

    /// v0 top left, v1 top right, v2 bottom left, v3 bottom right (1401b0410.c:579-638).
    private static func fillUVs(_ glyphs: inout WPEParityTextGlyphMesh, from atlas: WPEParityGlyphAtlas?) {
        for (quad, key) in glyphs.glyphKeys.enumerated() {
            guard let uv = atlas?.entry(forKey: key)?.uv else { continue }
            let base = quad * 4
            (glyphs.vertices[base].u, glyphs.vertices[base].v) = (uv.x, uv.y)
            (glyphs.vertices[base + 1].u, glyphs.vertices[base + 1].v) = (uv.z, uv.y)
            (glyphs.vertices[base + 2].u, glyphs.vertices[base + 2].v) = (uv.x, uv.w)
            (glyphs.vertices[base + 3].u, glyphs.vertices[base + 3].v) = (uv.z, uv.w)
        }
    }
}

private extension WPEParityTextGlyphMesh {
    mutating func removeQuads(_ quads: Set<Int>) {
        guard !quads.isEmpty else { return }
        var kept = WPEParityTextGlyphMesh()
        for (quad, key) in glyphKeys.enumerated() where !quads.contains(quad) {
            let (topLeft, bottomRight) = (vertices[quad * 4], vertices[quad * 4 + 3])
            kept.appendQuad(key: key, x0: topLeft.x, x1: bottomRight.x, top: topLeft.y, bottom: bottomRight.y)
        }
        self = kept
    }
}
