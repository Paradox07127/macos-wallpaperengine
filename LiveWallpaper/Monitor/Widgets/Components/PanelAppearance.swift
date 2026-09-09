import LiveWallpaperCore
import SwiftUI

/// Shared widget card appearance, consumed by `PanelChrome`.
enum MonitorPanelAppearance {
    static let tintKey = "Monitor.WidgetTintHex"
    static let opacityKey = "Monitor.WidgetOpacity"
    static let glassKey = "Monitor.WidgetLiquidGlass"

    /// Glass is opt-in because compositing over animated wallpaper can increase energy use.
    static let defaultGlass = false

    /// An empty tint selects the default graphite gradient.
    static let defaultTintHex = ""
    static let defaultOpacity: Double = 1.0
    /// Keep a visible card surface behind the readouts.
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

    /// Requires native Liquid Glass support and Reduce Transparency off.
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

    /// Preserve the selected material opacity; Reduce Transparency requires a solid surface.
    /// `inkBacking` maintains text contrast independently.
    static func materialAlpha(_ opacity: Double, reduceTransparency: Bool) -> Double {
        reduceTransparency ? 1 : resolvedOpacity(opacity)
    }

    /// Add a local text backing only when compositing over white exceeds `groundCeiling`.
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

    /// Scale the glass tint with the same opacity setting as the painted fill.
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
