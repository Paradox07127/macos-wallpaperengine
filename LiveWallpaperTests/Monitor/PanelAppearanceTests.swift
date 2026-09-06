@testable import LiveWallpaper
import LiveWallpaperCore
import SwiftUI
import Testing

@Suite("Monitor widget card appearance")
struct PanelAppearanceTests {
    /// The slider advertises 0.25…1.0 and the stored value is the user's. The
    /// card's alpha once spanned only 0.90…1.0, so every setting painted the
    /// same near-solid card and someone asking for a faint panel got 0.925.
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
        // Reduce Transparency is the one thing allowed to override the choice.
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
            // An opaque card is its own ground, so it needs no halo behind the ink.
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

    /// Liquid Glass is the one card style that can be vetoed by something other
    /// than the user: Reduce Transparency turns off the transparency the whole
    /// material is made of, and below macOS 26 there is no Liquid Glass to draw.
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

    /// Opt-in, and not only because of the OS floor: glass re-samples what is
    /// behind it every frame, and behind these cards is a wallpaper that may be
    /// a live scene.
    @Test("glass is off until asked for")
    func glassIsOptIn() {
        #expect(MonitorPanelAppearance.defaultGlass == false)
    }

    /// The scrim has to stay lighter than the painted card's own fill — the
    /// point is that the wallpaper still shows through the body — while the
    /// opacity dial keeps meaning the same thing in both styles.
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

    /// A malformed stored hex must not paint the card black — same rule the
    /// painted fill already follows.
    @Test("a malformed tint falls back instead of painting black")
    func malformedTintFallsBack() {
        let bad = MonitorPanelAppearance.glassScrim(tintHex: "not-a-colour", opacity: 1)
        let designed = MonitorPanelAppearance.glassScrim(tintHex: "", opacity: 1)
        #expect(NSColor(bad).usingColorSpace(.sRGB) == NSColor(designed).usingColorSpace(.sRGB))
    }
}
