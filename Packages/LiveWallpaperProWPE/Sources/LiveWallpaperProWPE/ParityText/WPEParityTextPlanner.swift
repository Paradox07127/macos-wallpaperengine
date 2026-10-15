/// Lays out text and packs glyphs through one atlas/ref owner: bitmap keys include point size, prepared distance
/// keys share the font (1401b0410.c:274-349). FreeType faces retain actual sizes and one serial owner.
public final class WPEParityTextPlanner {
    private let fonts: WPEParityFontLibrary
    fileprivate struct HeldGlyphs {
        let atlas: String
        let mono: [UInt32]
        let color: [UInt32]
        let monoReset: UInt64
        let colorReset: UInt64?
    }

    /// Value state only. Atlas dictionaries, shelves, entries and pixel arrays are Swift COW values;
    /// the one font library/FT faces remain on this planner and never enter a prepared snapshot.
    fileprivate struct State {
        var atlases: [String: WPEParityGlyphAtlasInstance] = [:]
        var held: [String: HeldGlyphs] = [:]
        var resets: [String: Int] = [:]
    }
    fileprivate enum Disposition: Equatable { case pending, accepted, discarded }
    private var state = State()
    private var revision: UInt64 = 0

    /// One candidate value snapshot, not another atlas or font owner. Use only on the planner's serial owner.
    /// Drop/discard it on a failed GPU preparation; old active layouts/references/pixels remain unchanged.
    public final class PreparedPlan {
        public let layout: WPEParityTextLayout
        public let atlasKey: String
        public let atlases: [String: WPEParityGlyphAtlasInstance]
        let resets: [String: Int]
        fileprivate weak var owner: WPEParityTextPlanner?
        fileprivate let baseRevision: UInt64
        fileprivate var staged: State?
        fileprivate var disposition = Disposition.pending

        fileprivate init(owner: WPEParityTextPlanner, revision: UInt64, state: State,
                         layout: WPEParityTextLayout, atlasKey: String) {
            self.owner = owner; baseRevision = revision; staged = state
            self.layout = layout; self.atlasKey = atlasKey
            atlases = state.atlases; resets = state.resets
        }
    }

    /// Keyed by the existing atlas instance key. Even a dirty-state writeback invalidates older pending plans.
    public var atlases: [String: WPEParityGlyphAtlasInstance] {
        get { state.atlases }
        set { state.atlases = newValue; revision &+= 1 }
    }
    public var resets: [String: Int] { state.resets }

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
        Self.hold(objectID: objectID, mesh: layout.mesh, atlasKey: atlasKey, state: &state)
        revision &+= 1
    }

    /// The layout of `object` with every quad's UVs taken from its atlas instance, and that instance's key. Glyphs
    /// already in the atlas are not rasterised again.
    public func plan(_ object: WPEParityTextObject, effectCount: Int) -> (layout: WPEParityTextLayout, atlasKey: String) {
        var next = state
        let result = pack(object, layout: layout(object, effectCount: effectCount), glyphMode: .bitmap, state: &next)
        state = next; revision &+= 1
        return result
    }

    /// Explicit preparation for a caller that will atomically admit the matching font PSO, constants and
    /// texture binding. The existing pipeline does not enable this merely because JSON requests MSDF.
    /// Unsupported COLOR/zero-area inputs fail before releasing previous references or changing atlases.
    public func plan(_ object: WPEParityTextObject, effectCount: Int, glyphMode: WPEParityTextGlyphMode)
        throws -> (layout: WPEParityTextLayout, atlasKey: String) {
        try accept(prepare(object, effectCount: effectCount, glyphMode: glyphMode))
    }

    /// Stages through the very same layout and pack path, without publishing any atlas/ref/reset mutation.
    /// FT metadata/scratch may be reused on this serial owner; no FT pointer is stored in the candidate.
    public func prepare(_ object: WPEParityTextObject, effectCount: Int,
                        glyphMode: WPEParityTextGlyphMode = .bitmap) throws -> PreparedPlan {
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
        var next = state
        let result = pack(object, layout: layout, glyphMode: glyphMode, state: &next)
        return PreparedPlan(owner: self, revision: revision, state: next,
                            layout: result.layout, atlasKey: result.atlasKey)
    }

    /// All fallible GPU preparation must precede this call. After it succeeds, the caller publishes its GPU
    /// candidate on the same serial owner without another throwing operation or suspension.
    @discardableResult
    public func accept(_ prepared: PreparedPlan) throws -> (layout: WPEParityTextLayout, atlasKey: String) {
        guard prepared.owner === self else { throw WPEParityTextPreparationError.foreignPreparedUpdate }
        guard prepared.disposition == .pending, let next = prepared.staged else {
            throw WPEParityTextPreparationError.preparedUpdateConsumed
        }
        guard prepared.baseRevision == revision else { throw WPEParityTextPreparationError.stalePreparedUpdate }
        state = next; revision &+= 1
        prepared.staged = nil; prepared.disposition = .accepted
        return (prepared.layout, prepared.atlasKey)
    }

    public func discard(_ prepared: PreparedPlan) throws {
        guard prepared.owner === self else { throw WPEParityTextPreparationError.foreignPreparedUpdate }
        guard prepared.disposition == .pending else { throw WPEParityTextPreparationError.preparedUpdateConsumed }
        prepared.staged = nil; prepared.disposition = .discarded
    }

    private func pack(_ object: WPEParityTextObject, layout: WPEParityTextLayout,
                      glyphMode: WPEParityTextGlyphMode, state: inout State)
        -> (layout: WPEParityTextLayout, atlasKey: String) {
        var layout = layout
        let pointSize = layout.mesh?.pointSize ?? WPEParityFontLibrary.clampedPointSize(object.pointSize)
        let key = WPEParityGlyphAtlasInstance.key(fontPath: object.font, pointSize: pointSize, glyphMode: glyphMode)
        // Release against the stored instance before copying it. Releasing the dictionary after the copy would
        // be lost when the same-key instance is written back. Empty text must release its previous mesh too.
        Self.release(objectID: object.id, state: &state)
        guard var mesh = layout.mesh else { return (layout, key) }
        let chain = fonts.chain(fontPath: object.font, pointSize: pointSize)
        var instance = state.atlases[key] ?? WPEParityGlyphAtlasInstance(fontPath: object.font, pointSize: pointSize,
                                                                 glyphMode: glyphMode)
        precondition(instance.glyphMode == glyphMode)
        let mono = Self.pack(mesh.mono, .mono, chain: chain, into: &instance)
        let color = Self.pack(mesh.color, .color, chain: chain, into: &instance)
        mesh.mono.removeQuads(mono.skipped)
        mesh.color.removeQuads(color.skipped)
        mesh.mono.atlasResetGeneration = instance.mono.resetGeneration
        mesh.color.atlasResetGeneration = instance.color?.resetGeneration
        if mono.reset || color.reset {
            state.resets[key, default: 0] += 1
        }

        state.atlases[key] = instance
        Self.hold(objectID: object.id, mesh: mesh, atlasKey: key, state: &state)

        Self.fillUVs(&mesh.mono, from: instance.mono)
        Self.fillUVs(&mesh.color, from: instance.color)
        layout.mesh = mesh
        return (layout, key)
    }

    private static func hold(objectID: String, mesh: WPEParityTextMesh?, atlasKey: String, state: inout State) {
        state.held[objectID] = HeldGlyphs(atlas: atlasKey, mono: mesh?.mono.glyphKeys ?? [],
                                         color: mesh?.color.glyphKeys ?? [],
                                         monoReset: mesh?.mono.atlasResetGeneration
                                             ?? state.atlases[atlasKey]?.mono.resetGeneration ?? 0,
                                         colorReset: mesh?.color.atlasResetGeneration
                                             ?? state.atlases[atlasKey]?.color?.resetGeneration)
    }

    private static func release(objectID: String, state: inout State) {
        guard let previous = state.held.removeValue(forKey: objectID) else { return }
        if state.atlases[previous.atlas]?.mono.resetGeneration == previous.monoReset {
            state.atlases[previous.atlas]?.mono.release(previous.mono)
        }
        if state.atlases[previous.atlas]?.color?.resetGeneration == previous.colorReset {
            state.atlases[previous.atlas]?.color?.release(previous.color)
        }
    }

    /// Re-reads UVs from active state, or from one prepared value snapshot for a staged shared-reader update.
    public func refreshUVs(_ layout: inout WPEParityTextLayout, atlasKey: String) {
        Self.refreshUVs(&layout, atlasKey: atlasKey, atlases: state.atlases)
    }

    func refreshUVs(_ layout: inout WPEParityTextLayout, atlasKey: String, prepared: PreparedPlan) {
        Self.refreshUVs(&layout, atlasKey: atlasKey, atlases: prepared.atlases)
    }

    private static func refreshUVs(_ layout: inout WPEParityTextLayout, atlasKey: String,
                                   atlases: [String: WPEParityGlyphAtlasInstance]) {
        guard var mesh = layout.mesh, let instance = atlases[atlasKey] else { return }
        fillUVs(&mesh.mono, from: instance.mono)
        fillUVs(&mesh.color, from: instance.color)
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
