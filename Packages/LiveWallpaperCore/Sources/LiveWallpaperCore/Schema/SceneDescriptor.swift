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
    /// User `project.json` property overrides; empty until the inspector is used.
    public let propertyOverrides: [String: WallpaperEngineProjectPropertyValue]

    public init(
        workshopID: String,
        cacheRelativePath: String,
        entryFile: String,
        capabilityTier: SceneCapabilityTier,
        assetStorage: SceneAssetStorage = .cache,
        dependencyWorkshopIDs: [String] = [],
        preflightTier: WPEScenePreflightTier? = nil,
        preflightFeatureFlags: [WPESceneFeatureFlag] = [],
        propertyOverrides: [String: WallpaperEngineProjectPropertyValue] = [:]
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
    }

    public func withPropertyOverrides(
        _ overrides: [String: WallpaperEngineProjectPropertyValue]
    ) -> SceneDescriptor {
        SceneDescriptor(
            workshopID: workshopID,
            cacheRelativePath: cacheRelativePath,
            entryFile: entryFile,
            capabilityTier: capabilityTier,
            assetStorage: assetStorage,
            dependencyWorkshopIDs: dependencyWorkshopIDs,
            preflightTier: preflightTier,
            preflightFeatureFlags: preflightFeatureFlags,
            propertyOverrides: overrides
        )
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
            return String(localized: "Image-only", defaultValue: "Image-only", comment: "Wallpaper Engine scene capability tier.")
        case .degraded:
            return String(localized: "Limited Compatibility", defaultValue: "Limited Compatibility", comment: "Wallpaper Engine scene capability tier.")
        case .unsupported:
            return String(localized: "Unsupported", defaultValue: "Unsupported", comment: "Wallpaper Engine scene capability tier.")
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
