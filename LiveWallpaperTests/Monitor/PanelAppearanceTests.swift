import SwiftUI
import Testing
@testable import LiveWallpaper

@Suite("Monitor widget card appearance")
struct PanelAppearanceTests {

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
