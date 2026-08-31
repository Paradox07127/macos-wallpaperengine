import Foundation

/// HTML content provenance for ephemeral WebKit storage forcing.
public enum HTMLOriginKind: String, Codable, Sendable, CaseIterable {
    /// User local/inline; `useEphemeralStorage` is authoritative.
    case userLocal
    /// Steam Workshop import — always ephemeral.
    case workshopImport
}

/// Per-screen behavior toggles for an HTML wallpaper.
public struct HTMLConfig: Codable, Equatable, Sendable {
    public var allowJavaScript: Bool = true
    public var allowMouseInteraction: Bool = false
    public var blockTrackers: Bool = true
    public var customCSS: String?
    /// Hard mute separate from `audioVolume` so unmute restores the prior level.
    public var muteAudio: Bool = false
    public var audioVolume: Double = 1.0
    /// Seconds; zero disables auto-reload.
    public var refreshIntervalSeconds: Int = 0
    public var transformScale: Double = 1.0
    public var transformTranslateX: Double = 0
    public var transformTranslateY: Double = 0
    public var transformRotationDegrees: Double = 0
    /// Retina physical-pixel canvas upgrade; off by default (double-scales with dPR-aware pages).
    public var physicalPixelLayout: Bool = false
    /// Nonpersistent data store on next rebuild; Workshop always forces nonpersistent.
    public var useEphemeralStorage: Bool = true
    public var originKind: HTMLOriginKind = .userLocal

    /// Workshop always forces `WKWebsiteDataStore.nonPersistent()`; local follows the toggle.
    public var requiresEphemeralStorage: Bool {
        switch originKind {
        case .workshopImport: return true
        case .userLocal:      return useEphemeralStorage
        }
    }

    /// Imported Workshop pages are third-party code that arrived over the
    /// network, so they render with every remote origin denied regardless of the
    /// opt-in CSP toggle. Content the user authored locally follows the toggle.
    public var requiresNetworkIsolation: Bool {
        switch originKind {
        case .workshopImport: true
        case .userLocal: false
        }
    }

    public var maxRetries: Int = 3
    /// CSP injection before scripts; off by default for authored-content compatibility.
    public var cspEnforcementEnabled: Bool = false
    /// Drop GPU canvas contexts while suspended; off — some pages cannot restore them.
    public var aggressiveSuspend: Bool = false
    /// Legacy flat WPE web-property overrides for `applyUserProperties`.
    public var wallpaperEngineProjectProperties: [String: WallpaperEngineProjectPropertyValue] = [:]
    /// Project-keyed overrides so same-named properties do not leak across projects.
    public var wallpaperEngineProjectPropertiesByProject: [String: [String: WallpaperEngineProjectPropertyValue]] = [:]

    public static let `default` = HTMLConfig()

    public static let minAudioVolume: Double = 0
    public static let maxAudioVolume: Double = 1
    /// Scale clamp: <0.1 is invisible; >3 clips heavily.
    public static let minTransformScale: Double = 0.1
    public static let maxTransformScale: Double = 3.0
    /// Translate clamp (~6K panel width); beyond that is almost always a typo.
    public static let maxTransformTranslate: Double = 3000
    public static let maxRefreshIntervalSeconds: Int = 24 * 60 * 60

    private enum CodingKeys: String, CodingKey {
        case allowJavaScript
        case allowMouseInteraction
        case blockTrackers
        case customCSS
        case muteAudio
        case audioVolume
        case refreshIntervalSeconds
        case transformScale
        case transformTranslateX
        case transformTranslateY
        case transformRotationDegrees
        case physicalPixelLayout
        case useEphemeralStorage
        case originKind
        case maxRetries
        case cspEnforcementEnabled
        case aggressiveSuspend
        case wallpaperEngineProjectProperties
        case wallpaperEngineProjectPropertiesByProject
    }

    public init(
        allowJavaScript: Bool = true,
        allowMouseInteraction: Bool = false,
        blockTrackers: Bool = true,
        customCSS: String? = nil,
        muteAudio: Bool = false,
        audioVolume: Double = 1.0,
        refreshIntervalSeconds: Int = 0,
        transformScale: Double = 1.0,
        transformTranslateX: Double = 0,
        transformTranslateY: Double = 0,
        transformRotationDegrees: Double = 0,
        physicalPixelLayout: Bool = false,
        useEphemeralStorage: Bool = true,
        originKind: HTMLOriginKind = .userLocal,
        maxRetries: Int = 3,
        cspEnforcementEnabled: Bool = false,
        aggressiveSuspend: Bool = false,
        wallpaperEngineProjectProperties: [String: WallpaperEngineProjectPropertyValue] = [:],
        wallpaperEngineProjectPropertiesByProject: [String: [String: WallpaperEngineProjectPropertyValue]] = [:]
    ) {
        self.allowJavaScript = allowJavaScript
        self.allowMouseInteraction = allowMouseInteraction
        self.blockTrackers = blockTrackers
        self.customCSS = customCSS
        self.muteAudio = muteAudio
        self.audioVolume = Self.clampedAudioVolume(audioVolume)
        self.refreshIntervalSeconds = Self.clampedRefreshInterval(refreshIntervalSeconds)
        self.transformScale = Self.clampedTransformScale(transformScale)
        self.transformTranslateX = Self.clampedTransformTranslate(transformTranslateX)
        self.transformTranslateY = Self.clampedTransformTranslate(transformTranslateY)
        self.transformRotationDegrees = Self.clampedTransformRotation(transformRotationDegrees)
        self.physicalPixelLayout = physicalPixelLayout
        self.useEphemeralStorage = useEphemeralStorage
        self.originKind = originKind
        self.maxRetries = maxRetries
        self.cspEnforcementEnabled = cspEnforcementEnabled
        self.aggressiveSuspend = aggressiveSuspend
        self.wallpaperEngineProjectProperties = wallpaperEngineProjectProperties
        self.wallpaperEngineProjectPropertiesByProject = wallpaperEngineProjectPropertiesByProject
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        allowJavaScript = try c.decodeIfPresent(Bool.self, forKey: .allowJavaScript) ?? true
        allowMouseInteraction = try c.decodeIfPresent(Bool.self, forKey: .allowMouseInteraction) ?? false
        blockTrackers = try c.decodeIfPresent(Bool.self, forKey: .blockTrackers) ?? true
        customCSS = try c.decodeIfPresent(String.self, forKey: .customCSS)
        muteAudio = try c.decodeIfPresent(Bool.self, forKey: .muteAudio) ?? false
        let decodedVolume = try c.decodeIfPresent(Double.self, forKey: .audioVolume) ?? 1.0
        audioVolume = Self.clampedAudioVolume(decodedVolume)
        let decodedRefresh = try c.decodeIfPresent(Int.self, forKey: .refreshIntervalSeconds) ?? 0
        refreshIntervalSeconds = Self.clampedRefreshInterval(decodedRefresh)
        let decodedScale = try c.decodeIfPresent(Double.self, forKey: .transformScale) ?? 1.0
        transformScale = Self.clampedTransformScale(decodedScale)
        let decodedTX = try c.decodeIfPresent(Double.self, forKey: .transformTranslateX) ?? 0
        transformTranslateX = Self.clampedTransformTranslate(decodedTX)
        let decodedTY = try c.decodeIfPresent(Double.self, forKey: .transformTranslateY) ?? 0
        transformTranslateY = Self.clampedTransformTranslate(decodedTY)
        let decodedRotation = try c.decodeIfPresent(Double.self, forKey: .transformRotationDegrees) ?? 0
        transformRotationDegrees = Self.clampedTransformRotation(decodedRotation)
        physicalPixelLayout = try c.decodeIfPresent(Bool.self, forKey: .physicalPixelLayout) ?? false
        useEphemeralStorage = try c.decodeIfPresent(Bool.self, forKey: .useEphemeralStorage) ?? true
        originKind = try c.decodeIfPresent(HTMLOriginKind.self, forKey: .originKind) ?? .userLocal
        let decodedRetries = try c.decodeIfPresent(Int.self, forKey: .maxRetries) ?? 3
        maxRetries = min(max(0, decodedRetries), 10)
        cspEnforcementEnabled = try c.decodeIfPresent(Bool.self, forKey: .cspEnforcementEnabled) ?? false
        aggressiveSuspend = try c.decodeIfPresent(Bool.self, forKey: .aggressiveSuspend) ?? false
        do {
            wallpaperEngineProjectProperties = try c.decodeIfPresent(
                [String: WallpaperEngineProjectPropertyValue].self,
                forKey: .wallpaperEngineProjectProperties
            ) ?? [:]
        } catch {
            // Malformed overrides must not fail the rest of the wallpaper decode.
            Logger.warning(
                "HTMLConfig: dropping unreadable wallpaperEngineProjectProperties (\(error.localizedDescription))",
                category: .settings
            )
            wallpaperEngineProjectProperties = [:]
        }
        do {
            wallpaperEngineProjectPropertiesByProject = try c.decodeIfPresent(
                [String: [String: WallpaperEngineProjectPropertyValue]].self,
                forKey: .wallpaperEngineProjectPropertiesByProject
            ) ?? [:]
        } catch {
            Logger.warning(
                "HTMLConfig: dropping unreadable wallpaperEngineProjectPropertiesByProject (\(error.localizedDescription))",
                category: .settings
            )
            wallpaperEngineProjectPropertiesByProject = [:]
        }
    }

    /// Project-keyed overrides, falling back to the legacy flat map for unmigrated configs.
    public func projectWallpaperEngineProperties(
        forProjectKey projectKey: String?
    ) -> [String: WallpaperEngineProjectPropertyValue] {
        guard let projectKey = Self.normalizedProjectKey(projectKey) else {
            return wallpaperEngineProjectProperties
        }
        return wallpaperEngineProjectPropertiesByProject[projectKey]
            ?? wallpaperEngineProjectProperties
    }

    /// Writes project-keyed overrides and clears the legacy flat map to stop name leak.
    public mutating func setWallpaperEngineProjectProperties(
        _ values: [String: WallpaperEngineProjectPropertyValue],
        forProjectKey projectKey: String?
    ) {
        guard let projectKey = Self.normalizedProjectKey(projectKey) else {
            wallpaperEngineProjectProperties = values
            return
        }

        if values.isEmpty {
            wallpaperEngineProjectPropertiesByProject.removeValue(forKey: projectKey)
        } else {
            wallpaperEngineProjectPropertiesByProject[projectKey] = values
        }
        wallpaperEngineProjectProperties = [:]
    }

    private static func normalizedProjectKey(_ projectKey: String?) -> String? {
        guard let projectKey = projectKey?.trimmingCharacters(in: .whitespacesAndNewlines),
              !projectKey.isEmpty else {
            return nil
        }
        return projectKey
    }

    public static func clampedAudioVolume(_ value: Double) -> Double {
        guard value.isFinite else { return 1.0 }
        return min(max(value, minAudioVolume), maxAudioVolume)
    }

    public static func clampedRefreshInterval(_ value: Int) -> Int {
        if value <= 0 { return 0 }
        return min(max(value, 5), maxRefreshIntervalSeconds)
    }

    public static func clampedTransformScale(_ value: Double) -> Double {
        guard value.isFinite else { return 1.0 }
        return min(max(value, minTransformScale), maxTransformScale)
    }

    public static func clampedTransformTranslate(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, -maxTransformTranslate), maxTransformTranslate)
    }

    public static func clampedTransformRotation(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        // Normalize to (-360, 360] so the persisted value stays readable.
        return value.truncatingRemainder(dividingBy: 360)
    }
}
