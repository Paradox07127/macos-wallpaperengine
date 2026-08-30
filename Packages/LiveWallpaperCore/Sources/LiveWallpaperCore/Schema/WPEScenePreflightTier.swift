import Foundation

/// Preflight verdict on `SceneDescriptor` (Core for Lite↔Pro lossless schema).
public enum WPEScenePreflightTier: String, Codable, Equatable, Sendable {
    case nativePlayable
    /// Playable with approximated features (e.g. effect shader mismatch).
    case degradedPlayable
    /// Missing runtime subsystem (today: lights; particle/text/sound/puppet warp ok).
    case runtimeSystemsRequired
    /// Hard macOS fail (Windows plugin / nothing renderable).
    case unsupported

    public var localizedLabel: String {
        switch self {
        case .nativePlayable:
            return String(localized: "Native", defaultValue: "Native", bundle: .appLanguage, comment: "Scene preflight tier label.")
        case .degradedPlayable:
            return String(localized: "Approximate", defaultValue: "Approximate", bundle: .appLanguage, comment: "Scene preflight tier label.")
        case .runtimeSystemsRequired:
            return String(localized: "Needs runtime systems", defaultValue: "Needs runtime systems", bundle: .appLanguage, comment: "Scene preflight tier label.")
        case .unsupported:
            return String(localized: "Unsupported", defaultValue: "Unsupported", bundle: .appLanguage, comment: "Scene preflight tier label.")
        }
    }
}

/// Preflight feature flags on `SceneDescriptor` (analyzer lives in ProWPE).
public enum WPESceneFeatureFlag: String, Codable, Hashable, Sendable {
    case customShaderSource
    case particleObject
    case textObject
    case soundObject
    case lightObject
    case animationLayer
    case imageEffect
    case unknownObject
    case windowsPlugin
}
