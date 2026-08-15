import Foundation

/// The audio half of Wallpaper Engine's per-wallpaper application settings, as
/// carried in a preset. See `WPEEngineColorCorrection` for how these keys were
/// identified and why they are not `project.json` properties.
///
/// Only `volume` is modelled. The block also carries `rate` (playback speed) and
/// the `alignment*` family, which are deliberately absent: parsing a value that
/// nothing applies would look like support while changing nothing, and this file
/// already had that failure once when the preset layer reached no consumer.
public struct WPEEngineAudioSettings: Equatable, Sendable {
    /// The author's level for this wallpaper, 0...1. Multiplies with the user's
    /// own master volume rather than replacing it — a preset states how loud the
    /// wallpaper should be relative to everything else, not how loud this Mac
    /// should be.
    public let volumeScale: Double

    public static let neutral = WPEEngineAudioSettings(volumeScale: 1)

    public var isNeutral: Bool { self == .neutral }

    public init(volumeScale: Double) {
        self.volumeScale = volumeScale
    }

    /// The rule itself, not just the parsed value: leaving the multiplication
    /// inline in the renderer left it uncovered — removing it there turned
    /// nothing red, because the tests only knew about parsing.
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
        // `isFinite` before the clamp: `min`/`max` pass NaN straight through,
        // and a manifest can carry the string "NaN". A NaN gain would also slip
        // the sound runtime's `abs(delta) > 0.001` guard, silently keeping the
        // old level rather than failing visibly.
        guard let raw = values[volumeKey]?.numberValue, raw.isFinite else { return nil }
        // 0...100 in the manifest, and clamped rather than trusted: the value
        // arrives from a downloaded file and ends up scaling a gain.
        return WPEEngineAudioSettings(volumeScale: min(max(raw, 0), 100) / 100)
    }
}
