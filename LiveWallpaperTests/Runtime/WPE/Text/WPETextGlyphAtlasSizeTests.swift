#if !LITE_BUILD
import CoreGraphics
import CoreText
import Foundation
@testable import LiveWallpaper
import Metal
import Testing

@Suite("WPE text glyph atlas size bounds")
struct WPETextGlyphAtlasSizeTests {
    private func glyphA(_ font: CTFont) throws -> CGGlyph {
        var character: UniChar = 0x41
        var glyph: CGGlyph = 0
        try #require(CTFontGetGlyphsForCharacters(font, &character, &glyph, 1))
        return glyph
    }

    private func cell(_ font: CTFont, _ glyph: CGGlyph) -> CGRect {
        var g = glyph
        return CTFontGetBoundingRectsForGlyphs(font, .horizontal, &g, nil, 1).integral
    }

    @Test("Normal point size glyph gets an atlas entry")
    func normalSize() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let atlas = WPETextGlyphAtlas(device: device)
        let font = CTFontCreateWithName("Helvetica" as CFString, 24, nil)
        let glyph = try glyphA(font)
        let entry = try #require(atlas.entry(glyph: glyph, font: font, cell: cell(font, glyph)))
        #expect(entry.cellSize.width > 0 && entry.cellSize.height > 0)
    }

    @Test("Point size beyond Int range drops the glyph instead of trapping")
    func hugeSize() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let atlas = WPETextGlyphAtlas(device: device)
        let font = CTFontCreateWithName("Helvetica" as CFString, 1e20, nil)
        let glyph = try glyphA(font)
        #expect(atlas.entry(glyph: glyph, font: font, cell: cell(font, glyph)) == nil)
        #expect(atlas.entry(glyph: glyph, font: font, cell: CGRect(x: 0, y: 0, width: 8, height: 8)) == nil)
        #expect(atlas.entry(glyph: glyph, font: font, cell: CGRect(x: 0, y: 0, width: CGFloat.nan, height: 8)) == nil)
    }
}
#endif
