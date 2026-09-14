import Foundation

/// Wallpaper Engine's per-wallpaper audio settings as carried in a preset. `rate` and
/// the `alignment*` family are deliberately unmodelled: parsing a value nothing applies
/// would look like support while changing nothing.
public struct WPEEngineAudioSettings: Equatable, Sendable {
    /// The author's level for this wallpaper, 0...1. Multiplies with the user's master
    /// volume rather than replacing it.
    public let volumeScale: Double

    public static let neutral = WPEEngineAudioSettings(volumeScale: 1)

    public var isNeutral: Bool { self == .neutral }

    public init(volumeScale: Double) {
        self.volumeScale = volumeScale
    }

    public static func effectiveVolume(master: Double, preset: WPEEngineAudioSettings?) -> Double {
        min(max(master, 0), 1) * (preset ?? .neutral).volumeScale
    }

    /// Public because it collides with a name scene authors use for their own
    /// properties, so the preset layer has to be able to recognise it.
    public static let volumeKey = "volume"

    /// `nil` when the preset carries no volume at all, which is every wallpaper
    /// that was never touched by one.
    public static func parse(
        _ values: [String: WallpaperEngineProjectPropertyValue]
    ) -> WPEEngineAudioSettings? {
        // `isFinite` before the clamp: `min`/`max` pass NaN straight through, and a manifest
        // can carry the string "NaN".
        guard let raw = values[volumeKey]?.numberValue, raw.isFinite else { return nil }
        // 0...100 in the manifest, and clamped rather than trusted.
        return WPEEngineAudioSettings(volumeScale: min(max(raw, 0), 100) / 100)
    }
}
