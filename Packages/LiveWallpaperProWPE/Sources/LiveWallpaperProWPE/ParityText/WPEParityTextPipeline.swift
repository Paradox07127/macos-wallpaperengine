/// A completed text update. The frame consumer can update geometry from the two layouts, and rebuild its graph
/// when the draw kinds, materials or FBO allocation changed. Unchanged layers are absent, in load order.
public struct WPEParityTextRelayoutDelta: Sendable {
    public struct Change: Sendable {
        public let previous: WPEParitySceneText
        public let current: WPEParitySceneText

        public var requiresFrameRebuild: Bool {
            func glyphLists(_ text: WPEParitySceneText) -> [Bool] {
                [text.layout.mesh != nil, !(text.layout.mesh?.mono.glyphKeys.isEmpty ?? true),
                 !(text.layout.mesh?.color.glyphKeys.isEmpty ?? true)]
            }
            func glyphCombos(_ text: WPEParitySceneText) -> [String: Int]? {
                guard let mesh = text.layout.mesh, mesh.glyphMode == .distanceField else { return [:] }
                return WPEParityTextDrawParameters(object: text.object, pointSize: mesh.pointSize)?.combos
            }
            let throughFBO = current.effectCount > 0 || current.object.composesThroughPassthrough
            return glyphLists(previous) != glyphLists(current)
                || previous.layout.mesh?.glyphMode != current.layout.mesh?.glyphMode
                || glyphCombos(previous) != glyphCombos(current)
                || previous.object.opaqueBackground != current.object.opaqueBackground
                || previous.object.colorBlendMode != current.object.colorBlendMode
                || previous.depthMaterials != current.depthMaterials
                || previous.effectCount != current.effectCount
                || throughFBO && previous.layout.fboSize != current.layout.fboSize
        }
    }

    public let changes: [Change]
}

/// The text layers of a scene and their shared atlases: each is laid out and packed at load, and a field change
/// re-lays it at once, as FUN_140256f20 does when a property is set. Holds FreeType objects: one owner at a time.
public final class WPEParityTextPipeline {
    public private(set) var texts: [String: WPEParitySceneText] = [:]
    /// Load order, which is also the order re-lays visit objects in.
    private var order: [String] = []
    private let planner: WPEParityTextPlanner
    private let hdr: Bool
    private let orthographic: Bool
    private var revision: UInt64 = 0

    public struct RelayoutRequest: Sendable {
        public let object: WPEParityTextObject
        public let effectCount: Int?
        public let glyphMode: WPEParityTextGlyphMode

        public init(_ object: WPEParityTextObject, effectCount: Int? = nil,
                    glyphMode: WPEParityTextGlyphMode = .bitmap) {
            self.object = object; self.effectCount = effectCount; self.glyphMode = glyphMode
        }
    }

    /// One staged update of this pipeline's existing owner. No FT/HB/atlas publisher is cloned.
    /// Its snapshots supply all inputs to the caller's candidate geometry/material/texture preparation.
    public final class PreparedUpdate {
        public let texts: [String: WPEParitySceneText]
        public let atlases: [String: WPEParityGlyphAtlasInstance]
        public let delta: WPEParityTextRelayoutDelta
        /// Union of actual intermediate changes in load order. Net-zero text changes can still add atlas pixels.
        public let changedObjectIDs: [String]
        fileprivate weak var owner: WPEParityTextPipeline?
        fileprivate let baseRevision: UInt64
        fileprivate let plan: WPEParityTextPlanner.PreparedPlan?
        fileprivate var consumed = false

        fileprivate init(owner: WPEParityTextPipeline, revision: UInt64,
                         texts: [String: WPEParitySceneText], atlases: [String: WPEParityGlyphAtlasInstance],
                         delta: WPEParityTextRelayoutDelta, changedObjectIDs: [String],
                         plan: WPEParityTextPlanner.PreparedPlan?) {
            self.owner = owner; baseRevision = revision
            self.texts = texts; self.atlases = atlases; self.delta = delta; self.plan = plan
            self.changedObjectIDs = changedObjectIDs
        }
    }

    /// Keyed by `WPEParityGlyphAtlasInstance.key`; whoever uploads them clears their dirty state.
    public var atlases: [String: WPEParityGlyphAtlasInstance] {
        get { planner.atlases }
        set { planner.atlases = newValue; revision &+= 1 }
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
        revision &+= 1
    }

    /// Re-reads every UV from the atlases as they are now: a later insert may have doubled one and halved the UVs.
    public func refreshUVs() {
        for id in order {
            guard var text = texts[id] else { continue }
            planner.refreshUVs(&text.layout, atlasKey: text.atlasKey)
            texts[id] = text
        }
        revision &+= 1
    }

    /// The new values of `object`'s layer. A field FUN_140256f20's dirty check covers lays it out again and packs
    /// the glyphs its atlas lacks, and every layer on an atlas that changed re-reads its UVs. When that resets the
    /// atlas, the other layers on it keep their stale UVs, as WPE's do. Returns the changed layers, in load order.
    @discardableResult
    public func relayout(_ object: WPEParityTextObject) -> [String] {
        relayoutWithDelta(object).changes.map(\.current.object.id)
    }

    /// Rebuilds the changed text once, including when its active effects change. The returned layouts already
    /// include any shared-atlas UV changes; the frame consumer need not run a speculative layout first.
    public func relayoutWithDelta(_ object: WPEParityTextObject, effectCount: Int? = nil)
        -> WPEParityTextRelayoutDelta {
        // Preserve the legacy bitmap entry through the same staging algorithm. Its preparation has no
        // admission failures and the immediate accept cannot become stale on this serial owner.
        do {
            guard let prepared = try prepareRelayout(object, effectCount: effectCount, glyphMode: .bitmap) else {
                return WPEParityTextRelayoutDelta(changes: [])
            }
            return try accept(prepared)
        } catch {
            preconditionFailure("Synchronous bitmap relayout failed its own fresh preparation: \(error)")
        }
    }

    /// Stages layouts, shared-reader UVs and the planner's atlas/ref/reset values without publishing them.
    /// Callers use the returned snapshots for all fallible GPU work, then accept/publish on the same serial owner.
    public func prepareRelayout(_ object: WPEParityTextObject, effectCount: Int? = nil,
                                glyphMode: WPEParityTextGlyphMode = .bitmap) throws -> PreparedUpdate? {
        try prepareRelayouts([RelayoutRequest(object, effectCount: effectCount, glyphMode: glyphMode)])
    }

    /// Requests are supplied in the caller's actual dirty/canonical order; repeated IDs keep that order.
    /// Every item uses the same layout/pack/UV path against one working State, with one final accept token.
    /// Any item throwing drops all earlier staged atlas/ref/layout changes without touching active state.
    public func prepareRelayouts(_ requests: [RelayoutRequest]) throws -> PreparedUpdate? {
        var next = texts
        var prepared: WPEParityTextPlanner.PreparedPlan? = nil
        var changed: Set<String> = []
        for request in requests {
            let object = request.object, glyphMode = request.glyphMode
            guard let current = next[object.id] else { continue }
            let effects = request.effectCount ?? current.effectCount
            let previousMode = mode(of: current, atlases: prepared?.atlases ?? planner.atlases)
            guard object != current.object || effects != current.effectCount || glyphMode != previousMode else { continue }
            if glyphMode == .distanceField {
                guard object.usesGlyphEffects else { throw WPEParityTextPreparationError.distanceFieldNotRequested }
                guard WPEParityTextDrawParameters(object: object, pointSize: object.pointSize) != nil else {
                    throw WPEParityTextPreparationError.nonfiniteDrawParameters
                }
            }
            let beforeStep = next
            if !object.needsRebuild(from: current.object), effects == current.effectCount, glyphMode == previousMode {
                next[object.id] = WPEParitySceneText(object: object, effectCount: current.effectCount,
                                                   layout: current.layout, atlasKey: current.atlasKey, hdr: hdr,
                                                   orthographic: orthographic)
            } else {
                let resets = prepared?.resets ?? planner.resets
                let plan = try planner.prepare(object, effectCount: effects, glyphMode: glyphMode, continuing: prepared)
                prepared = plan
                next[object.id] = WPEParitySceneText(object: object, effectCount: effects, layout: plan.layout,
                                                   atlasKey: plan.atlasKey, hdr: hdr, orthographic: orthographic)
                let key = plan.atlasKey
                let stale = plan.resets[key] != resets[key] ? key : nil
                for id in order {
                    guard var text = next[id], text.atlasKey == key || text.atlasKey == current.atlasKey,
                          id == object.id || text.atlasKey != stale else { continue }
                    planner.refreshUVs(&text.layout, atlasKey: text.atlasKey, prepared: plan)
                    next[id] = text
                }
            }
            for id in order where beforeStep[id] != next[id] { changed.insert(id) }
        }
        guard !changed.isEmpty else { return nil }
        let delta = WPEParityTextRelayoutDelta(changes: order.compactMap { id in
            guard let previous = texts[id], let current = next[id], previous != current else { return nil }
            return WPEParityTextRelayoutDelta.Change(previous: previous, current: current)
        })
        return PreparedUpdate(owner: self, revision: revision, texts: next,
                              atlases: prepared?.atlases ?? planner.atlases, delta: delta,
                              changedObjectIDs: order.filter { changed.contains($0) }, plan: prepared)
    }

    /// The caller must publish its successful GPU candidate immediately after this, with no throw or await
    /// on the same serial owner. A stale/foreign/reused candidate changes neither active layouts nor atlases.
    @discardableResult
    public func accept(_ prepared: PreparedUpdate) throws -> WPEParityTextRelayoutDelta {
        guard prepared.owner === self else { throw WPEParityTextPreparationError.foreignPreparedUpdate }
        guard !prepared.consumed else { throw WPEParityTextPreparationError.preparedUpdateConsumed }
        guard prepared.baseRevision == revision else { throw WPEParityTextPreparationError.stalePreparedUpdate }
        if let plan = prepared.plan { try planner.accept(plan) }
        texts = prepared.texts
        prepared.consumed = true; revision &+= 1
        return prepared.delta
    }

    public func discard(_ prepared: PreparedUpdate) throws {
        guard prepared.owner === self else { throw WPEParityTextPreparationError.foreignPreparedUpdate }
        guard !prepared.consumed else { throw WPEParityTextPreparationError.preparedUpdateConsumed }
        if let plan = prepared.plan { try planner.discard(plan) }
        prepared.consumed = true
    }

    private func mode(of text: WPEParitySceneText,
                      atlases: [String: WPEParityGlyphAtlasInstance]? = nil) -> WPEParityTextGlyphMode {
        if let mesh = text.layout.mesh { return mesh.glyphMode }
        if let instance = (atlases ?? planner.atlases)[text.atlasKey] { return instance.glyphMode }
        // An empty prepared field has no mesh/allocated atlas; its exact native key still preserves mode.
        return text.atlasKey == WPEParityGlyphAtlasInstance.key(fontPath: text.object.font,
            pointSize: WPEParityFontLibrary.clampedPointSize(text.object.pointSize), glyphMode: .distanceField)
            ? .distanceField : .bitmap
    }

    /// Whether `object`'s new layout keeps the frame's shape: the same glyph lists, and the same FBO size when the
    /// layer draws through its FBO.
    public func keepsFrameShape(_ object: WPEParityTextObject) -> Bool {
        guard let current = texts[object.id] else { return false }
        let layout = object.needsRebuild(from: current.object)
            ? planner.layout(object, effectCount: current.effectCount, glyphMode: mode(of: current)) : current.layout
        let proposed = WPEParitySceneText(object: object, effectCount: current.effectCount, layout: layout,
                                          atlasKey: current.atlasKey, hdr: hdr, orthographic: orthographic)
        return !WPEParityTextRelayoutDelta.Change(previous: current, current: proposed).requiresFrameRebuild
    }

    private func place(_ object: WPEParityTextObject, effectCount: Int) {
        let (layout, atlasKey) = planner.plan(object, effectCount: effectCount)
        texts[object.id] = WPEParitySceneText(object: object, effectCount: effectCount, layout: layout,
                                              atlasKey: atlasKey, hdr: hdr, orthographic: orthographic)
    }
}
