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

    /// Dark layer between the glass and the readouts, needed because `.regular.tint()` shifts hue but not luminance —
    /// measured on macOS 27, raising tint alpha 0.55→0.82 moved the card's median luminance only 132→138, while every
    /// widget here draws light-on-dark. Tint alone left the faint chrome at 1.16:1 against the card; this scrim brings
    /// it to 2.33:1, against 2.82:1 for the painted card. Deliberately not opaque: the wallpaper's colour still comes
    /// through the body, and the glass ring and its refraction still show at the edge.
    static func glassScrim(tintHex: String, opacity: Double) -> Color {
        let alpha = resolvedOpacity(opacity)
        let base = color(fromHex: tintHex) ?? Design.oklch(0.212, 0.013, 74)
        return base.opacity(0.58 * alpha)
    }

    /// Top/bottom fill for the card. A custom tint keeps the designed
    /// light-to-dark falloff and alpha ratio instead of painting flat, so the
    /// panel still reads as a lit surface rather than a coloured rectangle.
    static func fill(tintHex: String, opacity: Double) -> (top: Color, bottom: Color) {
        let alpha = resolvedOpacity(opacity)
        guard let tint = color(fromHex: tintHex) else {
            return (Design.panelFillTop.opacity(alpha), Design.panelFillBottom.opacity(alpha))
        }
        return (
            tint.opacity(0.72 * alpha),
            tint.opacity(0.60 * alpha)
        )
    }
}
