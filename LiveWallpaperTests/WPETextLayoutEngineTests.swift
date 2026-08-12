#if !LITE_BUILD
import CoreText
import Foundation
import Testing
@testable import LiveWallpaper

/// The oracle-derived layout spec (memory `wpe-text-windows-model`): glyph em
/// = pointsize×300/72, FreeType metric selection, block-left/baseline₁ local
/// frame, and alignment anchored at the OBJECT ORIGIN (never a box).
struct WPETextLayoutEngineTests {

    private let font = CTFontCreateWithName("HelveticaNeue" as CFString, 100, nil)

    @Test("pointsize converts at 300 DPI (oracle: Monofur 20pt → 83.3px em)")
    func pointToPixelConstant() {
        #expect(abs(WPETextLayoutEngine.pixelsPerPoint - 300.0 / 72.0) < 1e-12)
    }

    @Test("Metrics come from hhea unless OS/2 USE_TYPO_METRICS is set")
    func metricsFollowFreeTypeSelection() throws {
        // HelveticaNeue has no USE_TYPO_METRICS flag → hhea metrics must match
        // what CoreText reports (CTFontGetAscent reads hhea).
        let metrics = WPETextFontMetricsReader.metrics(for: font)
        #expect(abs(metrics.ascender - Double(CTFontGetAscent(font))) < 0.5)
        #expect(abs(metrics.descender - Double(CTFontGetDescent(font))) < 0.5)
    }

    @Test("First baseline is local y=0 and lines advance by the rounded line height")
    func baselineFrame() throws {
        let layout = try #require(WPETextLayoutEngine.layout(text: "Ag\nAg", font: font))
        #expect(layout.lineCount == 2)
        let advance = layout.metrics.lineHeight.rounded()
        // Group by quad BOTTOM: line-1 bottoms hug baseline 0 (a descender
        // dips a fraction of a line), line-2 bottoms sit a full advance down.
        let line1 = layout.quads.filter { $0.rect.minY > -advance / 2 }
        let line2 = layout.quads.filter { $0.rect.minY <= -advance / 2 }
        #expect(!line1.isEmpty && !line2.isEmpty)
        let line1Top = line1.map(\.rect.maxY).max() ?? 0
        let line2Top = line2.map(\.rect.maxY).max() ?? 0
        #expect(abs(Double(line1Top - line2Top) - advance) < 1.5,
                "second line must sit exactly one line advance below the first")
    }

    @Test("Anchor offsets follow the origin-anchored alignment table")
    func anchorOffsets() throws {
        let layout = try #require(WPETextLayoutEngine.layout(text: "Hello", font: font))
        let a = layout.metrics.ascender
        let d = layout.metrics.descender
        let w = layout.blockWidth

        #expect(layout.anchorOffset(horizontalAlignment: "left", verticalAlignment: "top")
                == SIMD2<Double>(0, -a))
        #expect(layout.anchorOffset(horizontalAlignment: "right", verticalAlignment: "bottom")
                == SIMD2<Double>(-w, d))
        // valign=center, n=1: baseline₁ = origin − A/2 (oracle-exact on
        // republica/Monofur; the (n−1)·adv/2 term is zero for one line).
        let center = layout.anchorOffset(horizontalAlignment: "center", verticalAlignment: "center")
        #expect(center.x == -w / 2)
        #expect(abs(center.y + a / 2) < 1e-9)
    }

    @Test("valign=center multi-line block shifts by (n−1)·adv/2")
    func centerMultiline() throws {
        let one = try #require(WPETextLayoutEngine.layout(text: "Hi", font: font))
        let two = try #require(WPETextLayoutEngine.layout(text: "Hi\nHo", font: font))
        let advance = two.metrics.lineHeight.rounded()
        let oneY = one.anchorOffset(horizontalAlignment: "center", verticalAlignment: "center").y
        let twoY = two.anchorOffset(horizontalAlignment: "center", verticalAlignment: "center").y
        #expect(abs((twoY - oneY) - advance / 2) < 1e-9)
    }

    @Test("Lines center mutually inside the block")
    func mutualLineCentering() throws {
        let layout = try #require(WPETextLayoutEngine.layout(text: "iii\nMMMMMM", font: font))
        let advance = layout.metrics.lineHeight.rounded()
        let line1 = layout.quads.filter { $0.rect.minY > -advance / 2 }
        let line2 = layout.quads.filter { $0.rect.minY <= -advance / 2 }
        let center1 = ((line1.map(\.rect.minX).min() ?? 0) + (line1.map(\.rect.maxX).max() ?? 0)) / 2
        let center2 = ((line2.map(\.rect.minX).min() ?? 0) + (line2.map(\.rect.maxX).max() ?? 0)) / 2
        #expect(abs(Double(center1 - center2)) < 3,
                "short line must center on the wide line (oracle: in-block mutual centering)")
    }

    @Test("Whitespace advances the pen without emitting quads")
    func whitespaceAdvances() throws {
        let spaced = try #require(WPETextLayoutEngine.layout(text: "a a", font: font))
        let plain = try #require(WPETextLayoutEngine.layout(text: "aa", font: font))
        #expect(spaced.quads.count == 2)
        #expect(spaced.blockWidth > plain.blockWidth)
    }

    @Test("Quad rects are integer-aligned (WPE meshes land on whole pixels)")
    func integerQuads() throws {
        let layout = try #require(WPETextLayoutEngine.layout(text: "Wg7", font: font))
        for quad in layout.quads {
            #expect(quad.rect.minX == quad.rect.minX.rounded())
            #expect(quad.rect.minY == quad.rect.minY.rounded())
            #expect(quad.rect.width == quad.rect.width.rounded())
            #expect(quad.rect.height == quad.rect.height.rounded())
        }
    }

    @Test("Empty and whitespace-only text yields no layout")
    func emptyText() {
        #expect(WPETextLayoutEngine.layout(text: "", font: font) == nil)
        #expect(WPETextLayoutEngine.layout(text: "   ", font: font) == nil)
    }
}
#endif
