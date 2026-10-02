#if !LITE_BUILD
import CoreText
import Foundation
import Testing
@testable import LiveWallpaper

/// Layout spec: memory `wpe-text-windows-model`.
struct WPETextLayoutEngineTests {

    private let font = CTFontCreateWithName("HelveticaNeue" as CFString, 100, nil)

    @Test("pointsize converts at 300 DPI (oracle: Monofur 20pt → 83.3px em)")
    func pointToPixelConstant() {
        #expect(abs(WPETextLayoutEngine.pixelsPerPoint - 300.0 / 72.0) < 1e-12)
    }

    @Test("Metrics come from hhea unless OS/2 USE_TYPO_METRICS is set")
    func metricsFollowFreeTypeSelection() throws {
        // CTFontGetAscent reads hhea, so it is a valid oracle only for a face without USE_TYPO_METRICS (HelveticaNeue has none).
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
        let a = layout.metrics.ascender.rounded(.up)
        let d = layout.metrics.descender.rounded(.up)
        let w = layout.blockWidth

        #expect(layout.anchorOffset(horizontalAlignment: "left", verticalAlignment: "top")
                == SIMD2<Double>(0, -a))
        #expect(layout.anchorOffset(horizontalAlignment: "right", verticalAlignment: "bottom")
                == SIMD2<Double>(-w, d))
        // valign=center, n=1: baseline_1 = origin - A/2; the (n-1)*adv/2 term is zero for one line.
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

    @Test("Glyph raster boxes are whole pixels; centred placement keeps half pixels")
    func integerQuads() throws {
        let layout = try #require(WPETextLayoutEngine.layout(text: "Wg7", font: font))
        for quad in layout.quads {
            #expect(quad.cell.minX == quad.cell.minX.rounded())
            #expect(quad.cell.minY == quad.cell.minY.rounded())
            #expect(quad.rect.width == quad.rect.width.rounded())
            #expect(quad.rect.height == quad.rect.height.rounded())
            #expect(quad.rect.minY == quad.rect.minY.rounded())
        }
        let indents = WPETextLayoutEngine.lineIndents(inkRights: [10, 7], horizontalAlignment: "center")
        #expect(indents.lineIndents == [0, 1.5])
    }

    // MARK: - Oracle 2026-10-01 (RobotoMono pt24: em 100 px, advance 60). Menlo's 0.602 em advance stands in.

    private let mono = CTFontCreateWithName("Menlo-Regular" as CFString, 100, nil)

    /// Ink glyph count per line; a quad's baseline is `rect.minY - cell.minY`.
    private func inkCountsPerLine(_ layout: WPETextBlockLayout) -> [Int] {
        var counts = [Int](repeating: 0, count: layout.lineCount)
        for quad in layout.quads {
            let baseline = Double(quad.rect.minY - quad.cell.minY)
            let line = Int((-baseline / layout.lineAdvance).rounded())
            counts[line] += 1
        }
        return counts
    }

    @Test("limitwidth wraps greedily by word, measuring without the trailing space")
    func greedyWordWrap() throws {
        let probe = try #require(WPETextLayoutEngine.layout(text: "HH", font: mono, horizontalAlignment: "left"))
        let advance = Double(probe.quads[1].rect.minX - probe.quads[0].rect.minX)
        #expect(abs(advance - 60) < 1, "fixture font must have a ~60 px advance at em 100")

        let text = "aa bbb cccc ddddd eeeeee"
        let wide = try #require(WPETextLayoutEngine.layout(text: text, font: mono, maxWidth: 690))
        #expect(inkCountsPerLine(wide) == [9, 5, 6])
        let narrow = try #require(WPETextLayoutEngine.layout(text: text, font: mono, maxWidth: 400))
        #expect(inkCountsPerLine(narrow) == [5, 4, 5, 6])
    }

    @Test("A word wider than maxwidth breaks per character")
    func longWordBreaksPerCharacter() throws {
        let layout = try #require(WPETextLayoutEngine.layout(text: "aa eeeeee b", font: mono, maxWidth: 200))
        #expect(inkCountsPerLine(layout) == [2, 3, 3, 1])
    }

    @Test("spacing.x adds a fixed canvas-px step per glyph that the block width excludes after the last glyph")
    func spacingXAdvancesPen() throws {
        let plain = try #require(WPETextLayoutEngine.layout(text: "HHHH", font: mono, horizontalAlignment: "left"))
        let spaced = try #require(WPETextLayoutEngine.layout(
            text: "HHHH", font: mono, spacing: SIMD2(50, 0), horizontalAlignment: "left"
        ))
        let plainStep = Double(plain.quads[1].rect.minX - plain.quads[0].rect.minX)
        let spacedStep = Double(spaced.quads[1].rect.minX - spaced.quads[0].rect.minX)
        #expect(abs(spacedStep - plainStep - 50) < 1e-6)
        let lastInkRight = try #require(spaced.quads.last).rect.maxX
        #expect(abs(spaced.blockWidth - Double(lastInkRight)) < 1e-6)

        let right = try #require(WPETextLayoutEngine.layout(
            text: "HHHH", font: mono, spacing: SIMD2(50, 0), horizontalAlignment: "right"
        ))
        let anchor = right.anchorOffset(horizontalAlignment: "right", verticalAlignment: "top")
        let inkRight = try Double(#require(right.quads.last).rect.maxX)
        #expect(abs(anchor.x + inkRight) < 1e-6, "last glyph's ink right edge must land on origin.x")
    }

    @Test("spacing.y adds to the line advance")
    func spacingYAddsLineAdvance() throws {
        let plain = try #require(WPETextLayoutEngine.layout(text: "HH\nHH", font: mono))
        let spaced = try #require(WPETextLayoutEngine.layout(text: "HH\nHH", font: mono, spacing: SIMD2(0, 40)))
        #expect(spaced.lineAdvance == plain.lineAdvance + 40)
        let lineGap = Double(spaced.quads[0].rect.minY - spaced.quads[2].rect.minY)
        #expect(lineGap == plain.lineAdvance + 40)
    }

    @Test("Ascent and descent anchor on FreeType-rounded pixels (RobotoMono pt48: A 210, |D| 55, adv 264)")
    func verticalAnchorsUseRoundedMetrics() {
        let metrics = WPETextLineMetrics(ascender: 2146.0 / 2048 * 200, descender: 555.0 / 2048 * 200, lineGap: 0)
        func block(_ lines: Int) -> WPETextBlockLayout {
            WPETextBlockLayout(quads: [], blockWidth: 0, lineCount: lines, metrics: metrics, lineAdvance: 264)
        }
        #expect(block(1).anchorOffset(horizontalAlignment: "left", verticalAlignment: "bottom").y == 55)
        #expect(block(3).anchorOffset(horizontalAlignment: "left", verticalAlignment: "bottom").y == 55 + 2 * 264)
        #expect(block(1).anchorOffset(horizontalAlignment: "left", verticalAlignment: "top").y == -210)
        #expect(block(1).anchorOffset(horizontalAlignment: "left", verticalAlignment: "center").y == -105)
    }

    @Test("Wrapped lines centre by ink right inside the widest ink line, keeping half pixels")
    func multilineCenterUsesInkRight() {
        // tx4k L4 (origin.x 1980): line ink rights from the captured quads; measured pens 1803/1863.5/1834/1803.
        let wrapped = WPETextLayoutEngine.lineIndents(inkRights: [354, 233, 292, 354], horizontalAlignment: "center")
        #expect(wrapped.blockWidth == 354)
        let pens = wrapped.lineIndents.map { 1980 - wrapped.blockWidth / 2 + $0 }
        let measured = [1803, 1863.5, 1834, 1803]
        for (pen, expected) in zip(pens, measured) {
            #expect(abs(pen - expected) < 0.5)
        }
        // tx4k L5 right (origin.x 2600): every line's ink right edge lands on origin.x.
        let right = WPETextLayoutEngine.lineIndents(inkRights: [354, 233, 292, 354], horizontalAlignment: "right")
        for (indent, inkRight) in zip(right.lineIndents, [354.0, 233, 292, 354]) {
            #expect(2600 - right.blockWidth + indent + inkRight == 2600)
        }
    }

    @Test("Real layout centres each wrapped line by its own ink right edge")
    func realLayoutCentresByInkRight() throws {
        let layout = try #require(WPETextLayoutEngine.layout(
            text: "aa bbb cccc ddddd eeeeee", font: mono, horizontalAlignment: "center", maxWidth: 400
        ))
        var inkRight = [Double](repeating: -.infinity, count: layout.lineCount)
        var penLeft = [Double](repeating: .infinity, count: layout.lineCount)
        for quad in layout.quads {
            let line = Int((-Double(quad.rect.minY - quad.cell.minY) / layout.lineAdvance).rounded())
            inkRight[line] = max(inkRight[line], Double(quad.rect.maxX))
            penLeft[line] = min(penLeft[line], Double(quad.rect.minX - quad.cell.minX))
        }
        #expect(abs((inkRight.max() ?? 0) - layout.blockWidth) < 1e-6)
        for line in 0 ..< layout.lineCount {
            let widthFromPen = inkRight[line] - penLeft[line]
            #expect(abs(penLeft[line] - (layout.blockWidth - widthFromPen) / 2) < 1e-6)
        }
    }

    @Test("CRLF breaks lines exactly like LF, keeping empty paragraphs", arguments: ["Ag\nAg", "a\n\nb", "Hi\nthere\n"])
    func crlfMatchesLF(lf: String) throws {
        let crlf = lf.replacingOccurrences(of: "\n", with: "\r\n")
        let expected = try #require(WPETextLayoutEngine.layout(text: lf, font: font))
        let actual = try #require(WPETextLayoutEngine.layout(text: crlf, font: font))
        #expect(actual.lineCount == expected.lineCount)
        #expect(actual.blockWidth == expected.blockWidth)
        #expect(actual.quads.map(\.glyph) == expected.quads.map(\.glyph))
        #expect(actual.quads.map(\.rect) == expected.quads.map(\.rect))
    }

    @Test("Empty and whitespace-only text yields no layout")
    func emptyText() {
        #expect(WPETextLayoutEngine.layout(text: "", font: font) == nil)
        #expect(WPETextLayoutEngine.layout(text: "   ", font: font) == nil)
    }
}
#endif
