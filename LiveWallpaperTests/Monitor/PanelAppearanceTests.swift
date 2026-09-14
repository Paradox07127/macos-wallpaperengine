@testable import LiveWallpaper
import LiveWallpaperCore
import SwiftUI
import Testing

@Suite("Monitor widget card appearance")
struct PanelAppearanceTests {
    @Test("the card's alpha is the value the user asked for")
    func materialAlphaTracksTheSetting() throws {
        func alpha(_ color: Color) throws -> Double {
            try Double(#require(NSColor(color).usingColorSpace(.sRGB)).alphaComponent)
        }
        for value in [0.25, 0.5, 1.0] {
            let fill = MonitorPanelAppearance.fill(tintHex: "#3366FF", opacity: value)
            let top = try alpha(fill.top)
            let bottom = try alpha(fill.bottom)
            #expect(abs(top - value) < 0.001, "top alpha at \(value)")
            #expect(abs(bottom - value) < 0.001, "bottom alpha at \(value)")
        }
        let forced = MonitorPanelAppearance.fill(tintHex: "#3366FF", opacity: 0.25, reduceTransparency: true)
        #expect(try alpha(forced.top) == 1)
    }

    @Test("Reduced transparency is opaque and faint labels stay readable over white")
    func contrastSurvivesBrightBackgrounds() throws {
        func rgb(_ color: Color) throws -> NSColor {
            try #require(NSColor(color).usingColorSpace(.sRGB))
        }
        func luminance(_ components: [Double]) -> Double {
            let linear = components.map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
            return linear[0] * 0.2126 + linear[1] * 0.7152 + linear[2] * 0.0722
        }
        let ink = try rgb(Design.inkFaint)
        let foreground = luminance([ink.redComponent, ink.greenComponent, ink.blueComponent])
        for hex in ["", "#FFFFFF", "#FFFF00", "#00FFFF", "#FF00FF"] {
            let opaque = MonitorPanelAppearance.fill(tintHex: hex, opacity: 0.25, reduceTransparency: true)
            #expect(try rgb(opaque.top).alphaComponent == 1)
            #expect(try rgb(opaque.bottom).alphaComponent == 1)
            #expect(MonitorPanelAppearance.inkBacking(tintHex: hex, opacity: 0.25, reduceTransparency: true) == nil)

            // The faintest card the slider offers, over the brightest wallpaper
            // there is, with the ink's own backing between them.
            let fill = try rgb(MonitorPanelAppearance.fill(tintHex: hex, opacity: 0.25).top)
            let halo = try MonitorPanelAppearance
                .inkBacking(tintHex: hex, opacity: 0.25, reduceTransparency: false)
                .map { try rgb($0).alphaComponent } ?? 0
            let background = luminance([fill.redComponent, fill.greenComponent, fill.blueComponent].map {
                ($0 * fill.alphaComponent + 1 - fill.alphaComponent) * (1 - halo)
            })
            #expect((foreground + 0.05) / (background + 0.05) >= 4.5)
        }
    }

    @Test("Reduce Transparency overrides the switch")
    func reduceTransparencyWins() {
        #expect(!MonitorPanelAppearance.usesGlass(true, reduceTransparency: true))
        #expect(!MonitorPanelAppearance.usesGlass(false, reduceTransparency: true))
        #expect(!MonitorPanelAppearance.usesGlass(false, reduceTransparency: false))
    }

    @Test("the switch decides on an OS that has the material")
    func switchDecidesWhenAvailable() {
        let expected: Bool
        if #available(macOS 26.0, *) { expected = true } else { expected = false }
        #expect(MonitorPanelAppearance.usesGlass(true, reduceTransparency: false) == expected)
    }

    @Test("glass is off until asked for")
    func glassIsOptIn() {
        #expect(MonitorPanelAppearance.defaultGlass == false)
    }

    @Test("the glass scrim is lighter than the painted fill but tracks opacity")
    func glassScrimIsLighterAndTracksOpacity() {
        func alpha(_ color: Color) -> Double {
            Double(NSColor(color).usingColorSpace(.sRGB)?.alphaComponent ?? 1)
        }
        let hex = "#3366FF"
        let scrimFull = alpha(MonitorPanelAppearance.glassScrim(tintHex: hex, opacity: 1))
        let paintedFull = alpha(MonitorPanelAppearance.fill(tintHex: hex, opacity: 1).top)
        #expect(scrimFull < paintedFull)
        #expect(scrimFull > 0)

        let scrimHalf = alpha(MonitorPanelAppearance.glassScrim(tintHex: hex, opacity: 0.5))
        #expect(scrimHalf < scrimFull)
    }

    @Test("a malformed tint falls back instead of painting black")
    func malformedTintFallsBack() {
        let bad = MonitorPanelAppearance.glassScrim(tintHex: "not-a-colour", opacity: 1)
        let designed = MonitorPanelAppearance.glassScrim(tintHex: "", opacity: 1)
        #expect(NSColor(bad).usingColorSpace(.sRGB) == NSColor(designed).usingColorSpace(.sRGB))
    }
}
