/// The text layers of a scene and their shared atlases: each is laid out and packed at load, and a field change
/// re-lays it at once, as FUN_140256f20 does when a property is set. Holds FreeType objects: one owner at a time.
public final class WPEParityTextPipeline {
    public private(set) var texts: [String: WPEParitySceneText] = [:]
    /// Load order, which is also the order re-lays visit objects in.
    private var order: [String] = []
    private let planner: WPEParityTextPlanner
    private let hdr: Bool
    private let orthographic: Bool

    /// Keyed by `WPEParityGlyphAtlasInstance.key`; whoever uploads them clears their dirty state.
    public var atlases: [String: WPEParityGlyphAtlasInstance] {
        get { planner.atlases }
        set { planner.atlases = newValue }
    }

    public init(assets: WPEParityProgramAssets, hdr: Bool, orthographic: Bool) {
        planner = WPEParityTextPlanner(assets: assets)
        self.hdr = hdr
        self.orthographic = orthographic
    }

    /// Takes over `texts`, planned in this order against `atlases`, which hold their glyph references.
    public convenience init(assets: WPEParityProgramAssets, hdr: Bool, orthographic: Bool,
                            texts: [WPEParitySceneText], atlases: [String: WPEParityGlyphAtlasInstance]) {
        self.init(assets: assets, hdr: hdr, orthographic: orthographic)
        planner.atlases = atlases
        for text in texts {
            planner.adopt(objectID: text.object.id, layout: text.layout, atlasKey: text.atlasKey)
            self.texts[text.object.id] = text
            order.append(text.object.id)
        }
    }

    /// Lays out and packs a newly loaded text layer; `refreshUVs` must follow the last one.
    public func add(_ object: WPEParityTextObject, effectCount: Int) {
        if texts[object.id] == nil {
            order.append(object.id)
        }
        place(object, effectCount: effectCount)
    }

    /// Re-reads every UV from the atlases as they are now: a later insert may have doubled one and halved the UVs.
    public func refreshUVs() {
        for id in order {
            guard var text = texts[id] else { continue }
            planner.refreshUVs(&text.layout, atlasKey: text.atlasKey)
            texts[id] = text
        }
    }

    /// The new values of `object`'s layer. A field FUN_140256f20's dirty check covers lays it out again and packs
    /// the glyphs its atlas lacks, and every layer on an atlas that changed re-reads its UVs. When that resets the
    /// atlas, the other layers on it keep their stale UVs, as WPE's do. Returns the changed layers, in load order.
    @discardableResult
    public func relayout(_ object: WPEParityTextObject) -> [String] {
        guard let current = texts[object.id] else { return [] }
        let before = texts
        guard object.needsRebuild(from: current.object) else {
            texts[object.id] = WPEParitySceneText(object: object, effectCount: current.effectCount,
                                                  layout: current.layout, atlasKey: current.atlasKey, hdr: hdr,
                                                  orthographic: orthographic)
            return texts[object.id] == current ? [] : [object.id]
        }
        let resets = planner.resets
        place(object, effectCount: current.effectCount)
        let key = texts[object.id]?.atlasKey ?? current.atlasKey
        let stale = planner.resets[key] != resets[key] ? key : nil
        for id in order {
            guard var text = texts[id], text.atlasKey == key || text.atlasKey == current.atlasKey,
                  id == object.id || text.atlasKey != stale else { continue }
            planner.refreshUVs(&text.layout, atlasKey: text.atlasKey)
            texts[id] = text
        }
        return order.filter { texts[$0] != before[$0] }
    }

    /// Whether `object`'s new layout keeps the frame's shape: the same glyph lists, and the same FBO size when the
    /// layer draws through its FBO.
    public func keepsFrameShape(_ object: WPEParityTextObject) -> Bool {
        guard let current = texts[object.id] else { return false }
        guard object.needsRebuild(from: current.object) else { return true }
        let layout = planner.layout(object, effectCount: current.effectCount)
        func lists(_ layout: WPEParityTextLayout) -> [Bool] {
            [layout.mesh?.mono.glyphKeys.isEmpty ?? true, layout.mesh?.color.glyphKeys.isEmpty ?? true]
        }
        let throughFBO = current.effectCount > 0 || object.composesThroughPassthrough
        return lists(layout) == lists(current.layout) && (!throughFBO || layout.fboSize == current.layout.fboSize)
    }

    private func place(_ object: WPEParityTextObject, effectCount: Int) {
        let (layout, atlasKey) = planner.plan(object, effectCount: effectCount)
        texts[object.id] = WPEParitySceneText(object: object, effectCount: effectCount, layout: layout,
                                              atlasKey: atlasKey, hdr: hdr, orthographic: orthographic)
    }
}
