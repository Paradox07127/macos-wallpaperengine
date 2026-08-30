import Foundation

/// Wallpaper Engine's per-wallpaper colour correction, as carried in a preset. A published preset
/// holds two different things in one map: the wallpaper's own `project.json` properties, and
/// Wallpaper Engine's application-level settings for that wallpaper. The second group is not
/// declared in the base wallpaper's schema, so the property filter drops it — correctly, because
/// those keys are not properties. They still describe the look the preset's author published.
///
/// **How the key names and ranges were established**: not documented publicly, so they were read
/// off two real presets by different authors for different wallpapers. The same fifteen undeclared
/// keys appear in both, which is what identifies them as engine-written rather than author-authored.
/// One preset has `wec_e: false` with every `wec_*` at 50; the other has `wec_e: true` with
/// 50/80/46/80 — that pairing is what fixes **50 as neutral** and `wec_e` as the enable flag.
///
/// **What is inferred rather than known**: the transfer functions. The observed data pins the
/// neutral point and the enable flag, not the curve. These map onto the same semantics our video
/// path already uses (`CIColorControls`), so one slider position means the same thing whichever
/// wallpaper type it lands on — consistency inside this app, not bit-parity with Wallpaper Engine.
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

    /// True when applying this would change any pixel. The renderer skips the
    /// whole pass otherwise — a full-frame 4K pass that provably does nothing is
    /// not worth its bandwidth.
    public var isIdentity: Bool { self == .neutral }

    public init(brightness: Double, contrast: Double, saturation: Double, hueDegrees: Double) {
        self.brightness = brightness
        self.contrast = contrast
        self.saturation = saturation
        self.hueDegrees = hueDegrees
    }

    /// Every engine correction key starts with this. Exposed so the preset
    /// layer can tell an engine key from a `project.json` property the scene's
    /// own author named.
    public static let keyPrefix = "wec_"

    private enum Key {
        static let enabled = "wec_e"
        static let brightness = "wec_brs"
        static let contrast = "wec_con"
        static let saturation = "wec_sa"
        static let hue = "wec_hue"
    }

    /// Reads the correction out of a preset's value map. Returns `nil` when the map carries no
    /// correction block at all, which is every wallpaper that was never touched by a preset —
    /// distinct from a block that is present and switched off.
    public static func parse(
        _ values: [String: WallpaperEngineProjectPropertyValue]
    ) -> WPEEngineColorCorrection? {
        let sliders = [Key.brightness, Key.contrast, Key.saturation, Key.hue]
        guard values[Key.enabled] != nil || sliders.contains(where: { values[$0] != nil }) else {
            return nil
        }
        // An absent flag alongside present sliders is treated as on: the flag is
        // what a preset uses to say "off", so requiring it would silently ignore
        // a correction whose author only moved the sliders.
        guard values[Key.enabled]?.boolValue ?? true else { return .neutral }

        func slider(_ key: String) -> Double {
            // Clamped, not trusted: these arrive from a downloaded manifest and
            // end up as shader uniforms. `min`/`max` do NOT rescue a NaN — it
            // propagates through both — and a manifest can carry the string
            // "NaN", which parses to one. Non-finite falls back to neutral.
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
