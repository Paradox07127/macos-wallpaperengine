/// Lays out text and packs glyphs through one atlas/ref owner: bitmap keys include point size, prepared distance
/// keys share the font (1401b0410.c:274-349). FreeType faces retain actual sizes and one serial owner.
public final class WPEParityTextPlanner {
    private let fonts: WPEParityFontLibrary
    /// Keyed by `WPEParityGlyphAtlasInstance.key`; whoever uploads them clears their dirty state.
    public var atlases: [String: WPEParityGlyphAtlasInstance] = [:]
    /// The atlas and glyph keys each planned object holds a reference on, so eviction leaves them alone.
    private struct HeldGlyphs {
        let atlas: String
        let mono: [UInt32]
        let color: [UInt32]
        let monoReset: UInt64
        let colorReset: UInt64?
    }

    private var held: [String: HeldGlyphs] = [:]
    /// How often each atlas instance was reset because it was full at 4096.
    public private(set) var resets: [String: Int] = [:]

    public init(assets: WPEParityProgramAssets) {
        fonts = WPEParityFontLibrary(assets: assets)
    }

    /// The layout of `object` without packing its glyphs.
    public func layout(_ object: WPEParityTextObject, effectCount: Int,
                       glyphMode: WPEParityTextGlyphMode = .bitmap) -> WPEParityTextLayout {
        var input = object.layoutInput(effectCount: effectCount)
        input.glyphMode = glyphMode
        return WPEParityTextLayoutEngine.layout(input, fonts: fonts)
    }

    /// Takes over `layout`, planned for `objectID` against `atlases`, whose glyph references it already holds.
    public func adopt(objectID: String, layout: WPEParityTextLayout, atlasKey: String) {
        hold(objectID: objectID, mesh: layout.mesh, atlasKey: atlasKey)
    }

    /// The layout of `object` with every quad's UVs taken from its atlas instance, and that instance's key. Glyphs
    /// already in the atlas are not rasterised again.
    public func plan(_ object: WPEParityTextObject, effectCount: Int) -> (layout: WPEParityTextLayout, atlasKey: String) {
        pack(object, layout: layout(object, effectCount: effectCount), glyphMode: .bitmap)
    }

    /// Explicit preparation for a caller that will atomically admit the matching font PSO, constants and
    /// texture binding. The existing pipeline does not enable this merely because JSON requests MSDF.
    /// Unsupported COLOR/zero-area inputs fail before releasing previous references or changing atlases.
    public func plan(_ object: WPEParityTextObject, effectCount: Int, glyphMode: WPEParityTextGlyphMode)
        throws -> (layout: WPEParityTextLayout, atlasKey: String) {
        if glyphMode == .distanceField, !object.usesGlyphEffects {
            throw WPEParityTextPreparationError.distanceFieldNotRequested
        }
        if glyphMode == .distanceField,
           WPEParityTextDrawParameters(object: object, pointSize: object.pointSize) == nil {
            throw WPEParityTextPreparationError.nonfiniteDrawParameters
        }
        let layout = layout(object, effectCount: effectCount, glyphMode: glyphMode)
        if glyphMode == .distanceField, let mesh = layout.mesh {
            guard mesh.color.glyphKeys.isEmpty else { throw WPEParityTextPreparationError.colorRequiresPairedAtlas }
            let chain = fonts.chain(fontPath: object.font, pointSize: mesh.pointSize)
            for key in Set(mesh.mono.glyphKeys) {
                let index = Int(key >> 24)
                if index < chain.faces.count, chain.faces[index].isColorFace {
                    throw WPEParityTextPreparationError.colorRequiresPairedAtlas
                }
                guard index < chain.faces.count,
                      let box = chain.faces[index].layoutGlyph(key & 0xFFFFFF, mode: .distanceField)?.box,
                      box.xMax > box.xMin, box.yMax > box.yMin else {
                    throw WPEParityTextPreparationError.zeroAreaDistanceGlyph
                }
            }
        }
        return pack(object, layout: layout, glyphMode: glyphMode)
    }

    private func pack(_ object: WPEParityTextObject, layout: WPEParityTextLayout,
                      glyphMode: WPEParityTextGlyphMode) -> (layout: WPEParityTextLayout, atlasKey: String) {
        var layout = layout
        let pointSize = layout.mesh?.pointSize ?? WPEParityFontLibrary.clampedPointSize(object.pointSize)
        let key = WPEParityGlyphAtlasInstance.key(fontPath: object.font, pointSize: pointSize, glyphMode: glyphMode)
        // Release against the stored instance before copying it. Releasing the dictionary after the copy would
        // be lost when the same-key instance is written back. Empty text must release its previous mesh too.
        release(objectID: object.id)
        guard var mesh = layout.mesh else { return (layout, key) }
        let chain = fonts.chain(fontPath: object.font, pointSize: pointSize)
        var instance = atlases[key] ?? WPEParityGlyphAtlasInstance(fontPath: object.font, pointSize: pointSize,
                                                                 glyphMode: glyphMode)
        precondition(instance.glyphMode == glyphMode)
        let mono = Self.pack(mesh.mono, .mono, chain: chain, into: &instance)
        let color = Self.pack(mesh.color, .color, chain: chain, into: &instance)
        mesh.mono.removeQuads(mono.skipped)
        mesh.color.removeQuads(color.skipped)
        mesh.mono.atlasResetGeneration = instance.mono.resetGeneration
        mesh.color.atlasResetGeneration = instance.color?.resetGeneration
        if mono.reset || color.reset {
            resets[key, default: 0] += 1
        }

        atlases[key] = instance
        hold(objectID: object.id, mesh: mesh, atlasKey: key)

        Self.fillUVs(&mesh.mono, from: instance.mono)
        Self.fillUVs(&mesh.color, from: instance.color)
        layout.mesh = mesh
        return (layout, key)
    }

    private func hold(objectID: String, mesh: WPEParityTextMesh?, atlasKey: String) {
        held[objectID] = HeldGlyphs(atlas: atlasKey, mono: mesh?.mono.glyphKeys ?? [],
                                    color: mesh?.color.glyphKeys ?? [],
                                    monoReset: mesh?.mono.atlasResetGeneration
                                        ?? atlases[atlasKey]?.mono.resetGeneration ?? 0,
                                    colorReset: mesh?.color.atlasResetGeneration
                                        ?? atlases[atlasKey]?.color?.resetGeneration)
    }

    private func release(objectID: String) {
        guard let previous = held.removeValue(forKey: objectID) else { return }
        if atlases[previous.atlas]?.mono.resetGeneration == previous.monoReset {
            atlases[previous.atlas]?.mono.release(previous.mono)
        }
        if atlases[previous.atlas]?.color?.resetGeneration == previous.colorReset {
            atlases[previous.atlas]?.color?.release(previous.color)
        }
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
        let counts = glyphs.glyphKeys.reduce(into: [UInt32: Int]()) { $0[$1, default: 0] += 1 }
        for round in 0 ..< 2 {
            skipped = []
            var full = false
            // Protect the new mesh's existing glyphs before the first insert, and new glyphs immediately after
            // insertion. Otherwise a later glyph in this very mesh can evict one of its earlier glyphs.
            for (key, count) in counts where entry(key, in: list, instance: instance) != nil {
                retain(key, count: count, in: list, instance: &instance)
            }
            for (quad, key) in glyphs.glyphKeys.enumerated() {
                guard entry(key, in: list, instance: instance) == nil else { continue }
                let face = Int(key >> 24)
                guard face < chain.faces.count else {
                    skipped.insert(quad)
                    continue
                }
                let inserted: Bool
                if instance.glyphMode == .distanceField {
                    guard list == .mono, let field = chain.faces[face].glyphField(key & 0xFFFFFF), !field.isColor else {
                        skipped.insert(quad)
                        continue
                    }
                    inserted = instance.insertDistanceField(key: key, field: field) != nil
                } else {
                    guard let bitmap = chain.faces[face].rasterize(key & 0xFFFFFF),
                          (bitmap.pixelMode == .bgra) == (list == .color) else {
                        skipped.insert(quad)
                        continue
                    }
                    inserted = instance.insert(key: key, bitmap: bitmap) != nil
                }
                if !inserted {
                    skipped.insert(quad)
                    if round == 0 {
                        full = true
                        break
                    }
                } else {
                    retain(key, count: counts[key] ?? 1, in: list, instance: &instance)
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

    private static func entry(_ key: UInt32, in list: WPEParityGlyphAtlasInstance.Atlas,
                              instance: WPEParityGlyphAtlasInstance) -> WPEParityGlyphAtlasEntry? {
        list == .mono ? instance.mono.entry(forKey: key) : instance.color?.entry(forKey: key)
    }

    private static func retain(_ key: UInt32, count: Int, in list: WPEParityGlyphAtlasInstance.Atlas,
                               instance: inout WPEParityGlyphAtlasInstance) {
        if list == .mono {
            instance.mono.retain(repeatElement(key, count: count))
        } else {
            instance.color?.retain(repeatElement(key, count: count))
        }
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
