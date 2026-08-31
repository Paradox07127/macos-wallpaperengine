@testable import LiveWallpaperCore
import Testing

@Suite("Floating glyph backing honours accessibility display settings")
struct FloatingGlyphBackingTests {
    /// The glyph floats over arbitrary wallpaper art, so Reduce Transparency has
    /// to win even where the OS offers Liquid Glass.
    @Test("Reduce Transparency outranks glass availability", arguments: [true, false])
    func reduceTransparencyOutranksAvailability(glassAvailable: Bool) {
        let backing = FloatingGlyphBacking.resolve(
            glassAvailable: glassAvailable,
            reduceTransparency: true,
            increasedContrast: false
        )
        #expect(backing == .opaque(bordered: false))
    }

    @Test("Increase Contrast adds an edge to the opaque disc")
    func increaseContrastAddsBorder() {
        #expect(
            FloatingGlyphBacking.resolve(
                glassAvailable: true,
                reduceTransparency: true,
                increasedContrast: true
            ) == .opaque(bordered: true)
        )
    }

    /// Increase Contrast on its own must not cost the glass treatment — only
    /// Reduce Transparency does that.
    @Test("Increase Contrast alone keeps glass")
    func increaseContrastAloneKeepsGlass() {
        #expect(
            FloatingGlyphBacking.resolve(
                glassAvailable: true,
                reduceTransparency: false,
                increasedContrast: true
            ) == .glass
        )
    }

    @Test("Without glass the pre-26 tint stays the default")
    func fallsBackToTintWithoutGlass() {
        #expect(
            FloatingGlyphBacking.resolve(
                glassAvailable: false,
                reduceTransparency: false,
                increasedContrast: false
            ) == .tinted
        )
    }
}
