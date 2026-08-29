import SwiftUI

/// Board-wide widget card appearance: one tint and one opacity shared by every
/// widget, read by `PanelChrome`.
///
/// Board-wide rather than per-widget on purpose — the point of the board is that
/// the tiles read as one surface, and eight independently tinted cards read as a
/// ransom note. Per-widget overrides can layer on later without moving this.
enum MonitorPanelAppearance {
    static let tintKey = "Monitor.WidgetTintHex"
    static let opacityKey = "Monitor.WidgetOpacity"

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
        var text = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        return Color(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    static func hex(from color: Color) -> String {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? NSColor.black
        let r = Int((ns.redComponent * 255).rounded())
        let g = Int((ns.greenComponent * 255).rounded())
        let b = Int((ns.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
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
