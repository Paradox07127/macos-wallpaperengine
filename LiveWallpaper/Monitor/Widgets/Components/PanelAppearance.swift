import LiveWallpaperCore
import SwiftUI

/// Board-wide widget card appearance — one tint, one opacity, shared by every widget and read by `PanelChrome`.
/// Deliberately board-wide, not per-widget: the point of the board is tiles reading as one surface, and eight
/// independently tinted cards read as a ransom note. Per-widget overrides can layer on later without moving
/// this.
enum MonitorPanelAppearance {
    static let tintKey = "Monitor.WidgetTintHex"
    static let opacityKey = "Monitor.WidgetOpacity"
    static let glassKey = "Monitor.WidgetLiquidGlass"

    /// Off by default, and not only because it needs macOS 26: glass re-samples what's behind it every frame, and
    /// what's behind these cards may itself be a video or a live scene — cost scales with tile count and never goes
    /// idle, unlike behind a static window. Apple's own guidance is to keep glass surfaces few and spend them on the
    /// most important controls; a board of nine instruments is the opposite of that. Still worth offering, and worth
    /// the user opting in to.
    static let defaultGlass = false

    /// Empty means "use the designed graphite gradient" — a stored colour that
    /// happened to equal the default would otherwise be indistinguishable from
    /// never having chosen one.
    static let defaultTintHex = ""
    static let defaultOpacity: Double = 1.0
    /// Floor is not 0: a fully transparent card leaves unreadable text floating
    /// on the wallpaper, which reads as a rendering bug rather than a choice.
    static let opacityRange: ClosedRange<Double> = 0.25...1.0

    static func resolvedOpacity(_ raw: Double) -> Double {
        guard raw > 0 else { return defaultOpacity }
        return min(max(raw, opacityRange.lowerBound), opacityRange.upperBound)
    }

    /// `#RRGGBB` / `RRGGBB`; nil for anything else so a malformed stored value
    /// falls back to the default rather than painting black.
    static func color(fromHex hex: String) -> Color? {
        guard let rgb = parseHexRGB(hex) else { return nil }
        return Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }

    /// `#RRGGBB` or `RRGGBB`, any case, as 0…1 components. `isHexDigit` is not
    /// redundant with the radix-16 init: `UInt32("+1F2A3", radix: 16)` accepts a sign.
    static func parseHexRGB(_ hex: String) -> (red: Double, green: Double, blue: Double)? {
        var text = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") {
            text.removeFirst()
        }
        guard text.count == 6,
              text.allSatisfy(\.isHexDigit),
              let value = UInt32(text, radix: 16)
        else { return nil }
        return (
            Double((value >> 16) & 0xFF) / 255,
            Double((value >> 8) & 0xFF) / 255,
            Double(value & 0xFF) / 255
        )
    }

    static func hex(from color: Color) -> String {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? NSColor.black
        let r = Int((ns.redComponent * 255).rounded())
        let g = Int((ns.greenComponent * 255).rounded())
        let b = Int((ns.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    /// Whether the cards should actually draw as Liquid Glass right now. Reduce Transparency is a hard no (the
    /// whole material is transparency), and below macOS 26 there's no Liquid Glass to draw, only an imitation —
    /// worse than the designed gradient this app already ships.
    static func usesGlass(_ enabled: Bool, reduceTransparency: Bool) -> Bool {
        guard enabled, !reduceTransparency else { return false }
        return AdaptiveGlass.isAvailable
    }

    /// Brightest channel a card's own colour is allowed to reach, and the ground
    /// the ink halo restores when the card is too faint to reach it on its own.
    /// Every widget draws light-on-dark, and a ground this dark clears 4.5:1 for
    /// `Design.inkFaint`, the palest ink on the board.
    private static let groundCeiling: Double = 0.14

    /// Keep light readouts legible even when the wallpaper or selected tint is white.
    /// Appearance opacity changes the material, never removes its contrast floor.
    static func readableTint(_ hex: String) -> Color {
        guard let rgb = parseHexRGB(hex) else { return Design.bg1 }
        let peak = max(rgb.red, rgb.green, rgb.blue, 0.001)
        let scale = min(1, groundCeiling / peak)
        return Color(red: rgb.red * scale, green: rgb.green * scale, blue: rgb.blue * scale)
    }

    /// The card's alpha, which is the user's value and nothing else: the dial
    /// exists for people who genuinely want a faint panel, so legibility is
    /// bought with `inkBacking` rather than by quietly refusing the setting.
    /// Reduce Transparency is the one override — that material has to be solid.
    static func materialAlpha(_ opacity: Double, reduceTransparency: Bool) -> Double {
        reduceTransparency ? 1 : resolvedOpacity(opacity)
    }

    /// Halo drawn behind a tile's own content, and nil when the card is already
    /// dark enough without it. A card at 0.25 over a white wallpaper leaves pale
    /// ink on a near-white ground, so the few points a glyph actually covers are
    /// darkened back to `groundCeiling` — the ground a solid card would give —
    /// instead of the whole panel being pushed opaque.
    static func inkBacking(tintHex: String, opacity: Double, reduceTransparency: Bool) -> Color? {
        let alpha = materialAlpha(opacity, reduceTransparency: reduceTransparency)
        let tint = NSColor(readableTint(tintHex)).usingColorSpace(.sRGB) ?? .black
        let peak = Double(max(tint.redComponent, tint.greenComponent, tint.blueComponent))
        // Worst case is a white wallpaper: wherever the card is not, 1 shows through.
        let overWhite = (1 - alpha) + alpha * peak
        guard overWhite > groundCeiling else { return nil }
        return .black.opacity(1 - groundCeiling / overWhite)
    }

    /// Soft enough to read as a halo rather than an outline at every tile size.
    static let inkBackingRadius: CGFloat = 3

    /// Lighter than the painted fill by design — the point of glass is that the
    /// wallpaper still comes through the body — and proportional, so the dial
    /// means the same thing in both card styles.
    static func glassScrim(tintHex: String, opacity: Double) -> Color {
        readableTint(tintHex).opacity(0.58 * resolvedOpacity(opacity))
    }

    static func fill(tintHex: String, opacity: Double, reduceTransparency: Bool = false) -> (top: Color, bottom: Color) {
        let alpha = materialAlpha(opacity, reduceTransparency: reduceTransparency)
        let tint = readableTint(tintHex)
        let bottom = NSColor(tint).usingColorSpace(.sRGB) ?? .black
        let shaded = Color(red: bottom.redComponent * 0.8, green: bottom.greenComponent * 0.8, blue: bottom.blueComponent * 0.8)
        return (tint.opacity(alpha), shaded.opacity(alpha))
    }
}
