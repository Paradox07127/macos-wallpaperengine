import Foundation

/// Persisted WPE `.scene` identity for restore across launches.
/// `cacheRelativePath` is under Application Support; joiners re-validate via path safety.
public struct SceneDescriptor: Codable, Equatable, Sendable {
    public let workshopID: String
    /// Relative to Application Support; must pass `WPEPathSafety.isSafeCacheRelativePath`.
    public let cacheRelativePath: String
    /// Historical default `.cache`; package/source modes read import in place (no second copy).
    public let assetStorage: SceneAssetStorage
    public let entryFile: String
    public let capabilityTier: SceneCapabilityTier
    public let dependencyWorkshopIDs: [String]
    /// Optional: pre-preflight descriptors decode as nil.
    public let preflightTier: WPEScenePreflightTier?
    /// Disk as `[String]` so unknown future flags round-trip without failing decode.
    public let preflightFeatureFlags: [WPESceneFeatureFlag]
    /// The user's own increment, applied *on top of* `presetID`'s values —
    /// not the full property set. Empty until the inspector is used.
    public private(set) var propertyOverrides: [String: WallpaperEngineProjectPropertyValue]
    /// `ScenePreset.id` of the applied preset, if any. Stored as a pointer
    /// rather than baked into `propertyOverrides` so that dropping the
    /// increment resets to the preset instead of to the scene defaults.
    public private(set) var presetID: String?
    /// The applied preset's values, carried alongside the pointer.
    /// Denormalised on purpose: the renderer receives a descriptor and
    /// nothing else — no route to `GlobalSettings.scenePresets` — so a
    /// pointer alone would mean the preset silently did nothing at render
    /// time. A separate layer from `propertyOverrides` is what preserves
    /// "drop the increment, keep the preset". `presetID` stays the
    /// authority for library operations (rename, delete, re-apply);
    /// `refreshingPresetSnapshot(in:)` re-syncs this copy when the library
    /// is at hand.
    public private(set) var presetSnapshot: [String: WallpaperEngineProjectPropertyValue]

    public init(
        workshopID: String,
        cacheRelativePath: String,
        entryFile: String,
        capabilityTier: SceneCapabilityTier,
        assetStorage: SceneAssetStorage = .cache,
        dependencyWorkshopIDs: [String] = [],
        preflightTier: WPEScenePreflightTier? = nil,
        preflightFeatureFlags: [WPESceneFeatureFlag] = [],
        propertyOverrides: [String: WallpaperEngineProjectPropertyValue] = [:],
        presetID: String? = nil,
        presetSnapshot: [String: WallpaperEngineProjectPropertyValue] = [:]
    ) {
        self.workshopID = workshopID
        self.cacheRelativePath = cacheRelativePath
        self.entryFile = entryFile
        self.capabilityTier = capabilityTier
        self.assetStorage = assetStorage
        self.dependencyWorkshopIDs = dependencyWorkshopIDs
        self.preflightTier = preflightTier
        self.preflightFeatureFlags = preflightFeatureFlags
        self.propertyOverrides = propertyOverrides
        self.presetID = presetID
        self.presetSnapshot = presetSnapshot
    }

    public func withPropertyOverrides(
        _ overrides: [String: WallpaperEngineProjectPropertyValue]
    ) -> SceneDescriptor {
        var copy = self
        copy.propertyOverrides = overrides
        return copy
    }

    /// Carries an existing preset layer (pointer + values) onto this descriptor
    /// without touching the increment. Used by restore paths that move both
    /// layers as a unit; use `applyingPreset(_:)` when the user picks a preset.
    public func withPresetLayer(
        id: String?,
        snapshot: [String: WallpaperEngineProjectPropertyValue]
    ) -> SceneDescriptor {
        var copy = self
        copy.presetID = id
        copy.presetSnapshot = id == nil ? [:] : snapshot
        return copy
    }

    /// Switching preset clears the increment: the old increment was
    /// authored against the previous preset's values, so carrying it over
    /// would silently re-apply edits made to a different look. Re-applying
    /// the preset already in place is a no-op, not a reset — clicking the
    /// selected preset again hasn't asked to lose edits. A preset belonging
    /// to another wallpaper is refused outright.
    public func applyingPreset(_ preset: ScenePreset?) -> SceneDescriptor {
        if let preset {
            guard preset.baseWorkshopID == workshopID else { return self }
            // Same preset re-applied: keep the user's edits, but still take the
            // values — the preset itself may have been edited since, and this is
            // the one path that would otherwise leave a stale snapshot forever.
            if preset.id == presetID {
                return preset.values == presetSnapshot
                    ? self
                    : withPresetLayer(id: preset.id, snapshot: preset.values)
            }
        }
        return withPresetLayer(id: preset?.id, snapshot: preset?.values ?? [:])
            .withPropertyOverrides([:])
    }

    /// The preset this descriptor points at, if the library still holds
    /// one that belongs to this scene. Two ways it can come back nil with
    /// a non-nil `presetID`: the preset was deleted, or its
    /// `baseWorkshopID` names a different wallpaper — both must resolve to
    /// "no preset" rather than someone else's values, or a stale id reused
    /// by a later preset would silently repaint the scene.
    public func resolvedPreset(in library: [String: ScenePreset]) -> ScenePreset? {
        guard let presetID, let preset = library[presetID] else { return nil }
        guard preset.id == presetID, preset.baseWorkshopID == workshopID else { return nil }
        return preset
    }

    /// Re-syncs the carried values against the library, and drops the whole
    /// layer when the preset no longer resolves. Call wherever the library is
    /// reachable — the snapshot is a cache, not a second source of truth.
    public func refreshingPresetSnapshot(in library: [String: ScenePreset]) -> SceneDescriptor {
        guard presetID != nil else { return self }
        guard let preset = resolvedPreset(in: library) else {
            return withPresetLayer(id: nil, snapshot: [:])
        }
        guard preset.values != presetSnapshot else { return self }
        return withPresetLayer(id: preset.id, snapshot: preset.values)
    }

    /// Values to hand the renderer, before the property schema folds in
    /// the scene's own defaults for keys nobody touched. Every render-path
    /// caller must use this instead of reading `propertyOverrides`
    /// directly: the increment alone is only half the look.
    public func layeredPropertyValues() -> [String: WallpaperEngineProjectPropertyValue] {
        guard presetID != nil, !presetSnapshot.isEmpty else { return propertyOverrides }
        return presetSnapshot.merging(propertyOverrides) { _, userEdit in userEdit }
    }

    /// Keys the engine reads out of a preset snapshot, which therefore may
    /// only ever be written by the engine settings UI. `volume` is the
    /// collision that matters: a perfectly ordinary name for a scene
    /// author's own `project.json` property, whose edits land in
    /// `propertyOverrides`.
    public static func isEngineReservedKey(_ key: String) -> Bool {
        key == WPEEngineAudioSettings.volumeKey
            || key.hasPrefix(WPEEngineColorCorrection.keyPrefix)
    }

    /// Values for a *new* preset snapshot capturing what is on screen.
    /// Layered like `layeredPropertyValues()`, except the increment may not
    /// supply engine-reserved keys: folding it in verbatim would promote an
    /// author's `volume` slider into the engine's master-gain slot, so
    /// saving a preset after touching that slider would rescale every sound
    /// in the scene.
    public func presetSnapshotForCurrentState() -> [String: WallpaperEngineProjectPropertyValue] {
        let authoredEdits = propertyOverrides.filter { !Self.isEngineReservedKey($0.key) }
        guard presetID != nil, !presetSnapshot.isEmpty else { return authoredEdits }
        return presetSnapshot.merging(authoredEdits) { _, userEdit in userEdit }
    }

    /// Same workshop item + entry (ignores overrides/preflight) for re-pick restore.
    public func isSameScene(as other: SceneDescriptor) -> Bool {
        workshopID == other.workshopID
            && cacheRelativePath == other.cacheRelativePath
            && entryFile == other.entryFile
    }

    private enum CodingKeys: String, CodingKey {
        case workshopID
        case cacheRelativePath
        case entryFile
        case capabilityTier
        case assetStorage
        case dependencyWorkshopIDs
        case preflightTier
        case preflightFeatureFlags
        case propertyOverrides
        case presetID
        case presetSnapshot
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        workshopID = try c.decode(String.self, forKey: .workshopID)
        cacheRelativePath = try c.decode(String.self, forKey: .cacheRelativePath)
        entryFile = try c.decode(String.self, forKey: .entryFile)
        capabilityTier = (try? c.decode(SceneCapabilityTier.self, forKey: .capabilityTier)) ?? .unsupported
        assetStorage = (try? c.decodeIfPresent(SceneAssetStorage.self, forKey: .assetStorage)) ?? .cache
        dependencyWorkshopIDs = (try? c.decodeIfPresent([String].self, forKey: .dependencyWorkshopIDs)) ?? []
        preflightTier = try? c.decodeIfPresent(WPEScenePreflightTier.self, forKey: .preflightTier)
        let rawFlags = (try? c.decodeIfPresent([String].self, forKey: .preflightFeatureFlags)) ?? []
        preflightFeatureFlags = rawFlags.compactMap(WPESceneFeatureFlag.init(rawValue:))
        propertyOverrides = (try? c.decodeIfPresent(
            [String: WallpaperEngineProjectPropertyValue].self,
            forKey: .propertyOverrides
        )) ?? [:]
        presetID = try? c.decodeIfPresent(String.self, forKey: .presetID)
        presetSnapshot = (try? c.decodeIfPresent(
            [String: WallpaperEngineProjectPropertyValue].self,
            forKey: .presetSnapshot
        )) ?? [:]
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(workshopID, forKey: .workshopID)
        try c.encode(cacheRelativePath, forKey: .cacheRelativePath)
        try c.encode(entryFile, forKey: .entryFile)
        try c.encode(capabilityTier, forKey: .capabilityTier)
        if assetStorage != .cache {
            try c.encode(assetStorage, forKey: .assetStorage)
        }
        try c.encode(dependencyWorkshopIDs, forKey: .dependencyWorkshopIDs)
        try c.encodeIfPresent(preflightTier, forKey: .preflightTier)
        try c.encode(preflightFeatureFlags.map(\.rawValue), forKey: .preflightFeatureFlags)
        if !propertyOverrides.isEmpty {
            try c.encode(propertyOverrides, forKey: .propertyOverrides)
        }
        try c.encodeIfPresent(presetID, forKey: .presetID)
        if !presetSnapshot.isEmpty {
            try c.encode(presetSnapshot, forKey: .presetSnapshot)
        }
    }
}

/// Import-time capability tier (avoids reparse before runtime fallback).
public enum SceneCapabilityTier: String, Codable, Equatable, Sendable {
    case imageOnly
    /// Decode-only. Nothing produces this any more: the middle tier flagged
    /// scenes for carrying particles/text/sound rather than for being broken.
    /// Kept because `SceneDescriptor` is persisted and older configs hold it —
    /// an unknown case would silently decode to `.unsupported`.
    case degraded
    /// Nothing renderable — UI placeholder.
    case unsupported

    public var localizedLabel: String {
        switch self {
        case .imageOnly:
            return String(localized: "Image-only", defaultValue: "Image-only", bundle: .appLanguage, comment: "Wallpaper Engine scene capability tier.")
        case .degraded:
            return String(localized: "Limited Compatibility", defaultValue: "Limited Compatibility", bundle: .appLanguage, comment: "Wallpaper Engine scene capability tier.")
        case .unsupported:
            return String(localized: "Unsupported", defaultValue: "Unsupported", bundle: .appLanguage, comment: "Wallpaper Engine scene capability tier.")
        }
    }
}

/// Runtime asset root; historical blobs default to `.cache`.
public enum SceneAssetStorage: Codable, Equatable, Sendable {
    /// Legacy extracted `wpe-cache/<id>`.
    case cache
    case sourceDirectory
    /// In-place packed archive under the import root (`fileName`, usually `scene.pkg`).
    case packageSource(fileName: String)
}
