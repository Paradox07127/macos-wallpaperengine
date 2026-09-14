import Foundation

/// Persisted WPE `.scene` identity for restore across launches.
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
    /// Stored as `[String]` so an unknown future flag doesn't fail decode.
    public let preflightFeatureFlags: [WPESceneFeatureFlag]
    /// The user's own increment, applied *on top of* `presetID`'s values —
    /// not the full property set. Empty until the inspector is used.
    public private(set) var propertyOverrides: [String: WallpaperEngineProjectPropertyValue]
    /// `ScenePreset.id` of the applied preset. A pointer rather than baked into
    /// `propertyOverrides`, so dropping the increment resets to the preset, not scene defaults.
    public private(set) var presetID: String?
    /// The applied preset's values, carried alongside the pointer. Denormalised on purpose: the
    /// renderer gets a descriptor and no route to `GlobalSettings.scenePresets`. `presetID` stays
    /// the authority for library operations; `refreshingPresetSnapshot(in:)` re-syncs this copy.
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

    /// Carries a preset layer onto this descriptor without touching the increment; use
    /// `applyingPreset(_:)` when the user picks a preset.
    public func withPresetLayer(
        id: String?,
        snapshot: [String: WallpaperEngineProjectPropertyValue]
    ) -> SceneDescriptor {
        var copy = self
        copy.presetID = id
        copy.presetSnapshot = id == nil ? [:] : snapshot
        return copy
    }

    /// Switching preset clears the increment: it was authored against the previous preset's
    /// values. Re-applying the preset already in place is a no-op, not a reset. A preset
    /// belonging to another wallpaper is refused outright.
    public func applyingPreset(_ preset: ScenePreset?) -> SceneDescriptor {
        if let preset {
            guard preset.baseWorkshopID == workshopID else { return self }
            // Same preset re-applied: keep the user's edits but still take the values — the preset
            // may have been edited since.
            if preset.id == presetID {
                return preset.values == presetSnapshot
                    ? self
                    : withPresetLayer(id: preset.id, snapshot: preset.values)
            }
        }
        return withPresetLayer(id: preset?.id, snapshot: preset?.values ?? [:])
            .withPropertyOverrides([:])
    }

    /// The preset this descriptor points at, if the library still holds one belonging to this
    /// scene. Two ways it comes back nil with a non-nil `presetID`: the preset was deleted, or
    /// its `baseWorkshopID` names a different wallpaper — a reused stale id must not repaint it.
    public func resolvedPreset(in library: [String: ScenePreset]) -> ScenePreset? {
        guard let presetID, let preset = library[presetID] else { return nil }
        guard preset.id == presetID, preset.baseWorkshopID == workshopID else { return nil }
        return preset
    }

    /// Re-syncs the carried values and drops the layer when the preset no longer resolves;
    /// the snapshot is a cache, not a second source of truth.
    public func refreshingPresetSnapshot(in library: [String: ScenePreset]) -> SceneDescriptor {
        guard presetID != nil else { return self }
        guard let preset = resolvedPreset(in: library) else {
            return withPresetLayer(id: nil, snapshot: [:])
        }
        guard preset.values != presetSnapshot else { return self }
        return withPresetLayer(id: preset.id, snapshot: preset.values)
    }

    /// Values to hand the renderer, before the property schema folds in the scene's defaults.
    /// Every render path must use this instead of `propertyOverrides`: the increment is half the look.
    public func layeredPropertyValues() -> [String: WallpaperEngineProjectPropertyValue] {
        guard presetID != nil, !presetSnapshot.isEmpty else { return propertyOverrides }
        return presetSnapshot.merging(propertyOverrides) { _, userEdit in userEdit }
    }

    /// Keys the engine reads out of a preset snapshot. `volume` is the collision that matters:
    /// it is also an ordinary `project.json` property name.
    public static func isEngineReservedKey(_ key: String) -> Bool {
        key == WPEEngineAudioSettings.volumeKey
            || key.hasPrefix(WPEEngineColorCorrection.keyPrefix)
    }

    /// Values for a *new* preset snapshot. Layered like `layeredPropertyValues()`, except the
    /// increment may not supply engine-reserved keys: folding an author's `volume` slider into
    /// the engine's master-gain slot would rescale every sound in the scene.
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
        propertyOverrides = c.decodeLossyStringDictionary(forKey: .propertyOverrides) ?? [:]
        presetID = try? c.decodeIfPresent(String.self, forKey: .presetID)
        presetSnapshot = c.decodeLossyStringDictionary(forKey: .presetSnapshot) ?? [:]
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
    /// Decode-only; nothing produces it any more. Kept because older persisted configs hold it
    /// and an unknown case would decode to `.unsupported`.
    case degraded
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
