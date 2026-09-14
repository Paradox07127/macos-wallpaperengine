import Foundation

/// Wallpaper Engine's per-wallpaper colour correction, as carried in a preset. These
/// are engine-level settings, not the base wallpaper's `project.json` properties, so
/// the property filter drops them.
public struct WPEEngineColorCorrection: Equatable, Sendable {
    /// Additive, −1...1, 0 neutral.
    public let brightness: Double
    /// Multiplier around mid grey, 0...2, 1 neutral.
    public let contrast: Double
    /// Multiplier against luma, 0...2, 1 neutral.
    public let saturation: Double
    /// Degrees, −180...180, 0 neutral.
    public let hueDegrees: Double

    public static let neutral = WPEEngineColorCorrection(
        brightness: 0, contrast: 1, saturation: 1, hueDegrees: 0
    )

    public var isIdentity: Bool { self == .neutral }

    public init(brightness: Double, contrast: Double, saturation: Double, hueDegrees: Double) {
        self.brightness = brightness
        self.contrast = contrast
        self.saturation = saturation
        self.hueDegrees = hueDegrees
    }

    public static let keyPrefix = "wec_"

    private enum Key {
        static let enabled = "wec_e"
        static let brightness = "wec_brs"
        static let contrast = "wec_con"
        static let saturation = "wec_sa"
        static let hue = "wec_hue"
    }

    /// Returns `nil` when the map carries no correction block at all — distinct from a
    /// block that is present and switched off.
    public static func parse(
        _ values: [String: WallpaperEngineProjectPropertyValue]
    ) -> WPEEngineColorCorrection? {
        let sliders = [Key.brightness, Key.contrast, Key.saturation, Key.hue]
        guard values[Key.enabled] != nil || sliders.contains(where: { values[$0] != nil }) else {
            return nil
        }
        // Absent flag with present sliders ⇒ on: requiring it would silently ignore a
        // correction whose author only moved the sliders.
        guard values[Key.enabled]?.boolValue ?? true else { return .neutral }

        func slider(_ key: String) -> Double {
            // Clamped, not trusted. `min`/`max` do NOT rescue a NaN and a manifest can carry the
            // string "NaN", so non-finite falls back to neutral.
            let raw = values[key]?.numberValue ?? 50
            return raw.isFinite ? min(max(raw, 0), 100) : 50
        }
        return WPEEngineColorCorrection(
            brightness: (slider(Key.brightness) - 50) / 50,
            contrast: slider(Key.contrast) / 50,
            saturation: slider(Key.saturation) / 50,
            hueDegrees: (slider(Key.hue) - 50) / 50 * 180
        )
    }
}
