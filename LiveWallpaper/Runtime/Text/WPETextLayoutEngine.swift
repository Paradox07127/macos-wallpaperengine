#if !LITE_BUILD
import CoreGraphics
import CoreText
import Foundation
import simd

/// Vertical line metrics in pixels at a concrete em size, resolved with FreeType's
/// table-selection rule so line spacing matches Wallpaper Engine: OS/2 `USE_TYPO_METRICS`
/// (fsSelection bit 7) selects the typo metrics, otherwise hhea metrics apply. (Oracle-verified
/// across 9 corpus fonts — p5hatty is the discriminating case; see memory `wpe-text-windows-model`.)
struct WPETextLineMetrics {
    /// Ascender above the baseline, pixels (positive).
    let ascender: Double
    /// Descender below the baseline, pixels (positive).
    let descender: Double
    /// Additional line gap, pixels.
    let lineGap: Double

    var lineHeight: Double { ascender + descender + lineGap }
}

enum WPETextFontMetricsReader {
    /// Reads head/hhea/OS2 directly: CTFontGetAscent always reports hhea
    /// metrics, which mis-sizes USE_TYPO_METRICS fonts by up to 25%.
    static func metrics(for font: CTFont) -> WPETextLineMetrics {
        let em = Double(CTFontGetSize(font))
        guard
            let head = CTFontCopyTable(font, CTFontTableTag(kCTFontTableHead), []) as Data?,
            let hhea = CTFontCopyTable(font, CTFontTableTag(kCTFontTableHhea), []) as Data?,
            head.count >= 20, hhea.count >= 10
        else {
            return WPETextLineMetrics(
                ascender: Double(CTFontGetAscent(font)),
                descender: Double(CTFontGetDescent(font)),
                lineGap: Double(CTFontGetLeading(font))
            )
        }
        let unitsPerEm = Double(readUInt16(head, 18))
        guard unitsPerEm > 0 else {
            return WPETextLineMetrics(ascender: em * 0.8, descender: em * 0.2, lineGap: 0)
        }
        var ascent = Double(readInt16(hhea, 4))
        var descent = Double(readInt16(hhea, 6))
        var gap = Double(readInt16(hhea, 8))
        if let os2 = CTFontCopyTable(font, CTFontTableTag(kCTFontTableOS2), []) as Data?,
           os2.count >= 74 {
            let fsSelection = readUInt16(os2, 62)
            if fsSelection & 0x80 != 0 {
                ascent = Double(readInt16(os2, 68))
                descent = Double(readInt16(os2, 70))
                gap = Double(readInt16(os2, 72))
            }
        }
        let scale = em / unitsPerEm
        return WPETextLineMetrics(
            ascender: ascent * scale,
            descender: abs(descent) * scale,
            lineGap: max(gap, 0) * scale
        )
    }

    private static func readUInt16(_ data: Data, _ offset: Int) -> UInt16 {
        guard data.count >= offset + 2 else { return 0 }
        return UInt16(data[data.startIndex + offset]) << 8 | UInt16(data[data.startIndex + offset + 1])
    }

    private static func readInt16(_ data: Data, _ offset: Int) -> Int16 {
        Int16(bitPattern: readUInt16(data, offset))
    }
}

/// One positioned glyph in block-local space: x=0 at the block's left edge,
/// the FIRST line's baseline at y=0, +y up (WPE author-space orientation).
struct WPETextGlyphQuad {
    let glyph: CGGlyph
    /// The run's resolved font (CoreText fallback may substitute per run).
    let runFont: CTFont
    /// The glyph's OWN integral raster box relative to its pen at the baseline
    /// (pure bearings, no placement) — what the atlas rasterizes. Same size as
    /// `rect` by construction.
    let cell: CGRect
    /// `cell` translated to the glyph's block-local position (pen + line +
    /// alignment offsets), integer-aligned.
    let rect: CGRect
}

/// A laid-out text block. The placement anchor is the OBJECT ORIGIN — WPE
/// aligns the block relative to that point; the authored `size` box does not
/// exist at runtime (oracle-verified, see memory `wpe-text-windows-model`).
struct WPETextBlockLayout {
    let quads: [WPETextGlyphQuad]
    /// Widest line's typographic width — the block's horizontal extent.
    let blockWidth: Double
    let lineCount: Int
    /// Primary font metrics at em pixels (line spacing uses these).
    let metrics: WPETextLineMetrics

    /// Baseline-to-baseline step, whole pixels (WPE's FreeType path rounds it).
    var lineAdvance: Double { metrics.lineHeight.rounded() }

    /// The block box WPE sizes its text FBO from: widest line by `n × advance`
    /// (2955378002's `padding: 31` measures as exactly this + 62 in the
    /// capture). Its top edge sits `metrics.ascender` above the first baseline.
    var blockSize: CGSize {
        CGSize(width: blockWidth, height: Double(lineCount) * lineAdvance)
    }

    /// Offset from the object origin to block-local (0,0) (block left edge at
    /// the first baseline), in author-space pixels (+y up), so that
    /// `world = origin + R·S·(offset + local)`.
    ///
    ///   left/center/right → block starts at / centers on / ends at origin.x
    ///   top    → first-line ascent top sits at origin.y
    ///   center → baseline₁ = origin.y − A/2 + (n−1)·adv/2
    ///   bottom → last-line descent bottom sits at origin.y (mirror of top —
    ///            no corpus sample; the other two are RenderDoc-exact)
    func anchorOffset(horizontalAlignment: String, verticalAlignment: String) -> SIMD2<Double> {
        let x: Double
        switch horizontalAlignment {
        case "left": x = 0
        case "right": x = -blockWidth
        default: x = -blockWidth / 2
        }
        let advance = (metrics.lineHeight).rounded()
        let y: Double
        switch verticalAlignment {
        case "top": y = -metrics.ascender
        case "bottom": y = metrics.descender + Double(lineCount - 1) * advance
        default: y = -metrics.ascender / 2 + Double(lineCount - 1) * advance / 2
        }
        return SIMD2<Double>(x, y)
    }
}

enum WPETextLayoutEngine {
    /// WPE rasterizes `pointsize` at 300 DPI: author-space pixels per point.
    /// (Oracle-verified em sizes across five fonts and four point sizes.)
    static let pixelsPerPoint = 300.0 / 72.0

    /// Lays out `text` with `font` already sized at em pixels. `maxWidth` (author
    /// px) wraps via CoreText line breaking when present; `maxRows` clamps the
    /// row count (appending `…` when `ellipsis`). Returns nil for empty text.
    static func layout(
        text: String,
        font: CTFont,
        letterSpacing: Double = 0,
        horizontalAlignment: String = "center",
        maxWidth: Double? = nil,
        maxRows: Int? = nil,
        ellipsis: Bool = false
    ) -> WPETextBlockLayout? {
        guard !text.isEmpty else { return nil }
        let metrics = WPETextFontMetricsReader.metrics(for: font)
        let lineAdvance = metrics.lineHeight.rounded()

        var lines = brokenLines(text: text, font: font, letterSpacing: letterSpacing, maxWidth: maxWidth)
        if let maxRows, maxRows > 0, lines.count > maxRows {
            lines = Array(lines.prefix(maxRows))
            if ellipsis, var last = lines.last {
                while let tail = last.last, tail.isWhitespace { last.removeLast() }
                lines[lines.count - 1] = last + "\u{2026}"
            }
        }
        guard !lines.isEmpty else { return nil }

        var lineLayouts: [(quads: [LineGlyph], width: Double)] = []
        for line in lines {
            lineLayouts.append(layoutLine(line, font: font, letterSpacing: letterSpacing))
        }
        let blockWidth = lineLayouts.map(\.width).max() ?? 0

        var quads: [WPETextGlyphQuad] = []
        for (index, line) in lineLayouts.enumerated() {
            let baselineY = -Double(index) * lineAdvance
            // Lines align mutually inside the block with the SAME mode the
            // block anchors with (oracle meshes: center-aligned scenes carry
            // mutually centered lines; left/right follow the flush edge).
            let indent: Double
            switch horizontalAlignment {
            case "left": indent = 0
            case "right": indent = blockWidth - line.width
            default: indent = (blockWidth - line.width) / 2
            }
            for glyph in line.quads {
                let placed = glyph.cell.offsetBy(
                    dx: (glyph.penX + indent).rounded(),
                    dy: baselineY
                )
                quads.append(WPETextGlyphQuad(
                    glyph: glyph.glyph, runFont: glyph.runFont, cell: glyph.cell, rect: placed
                ))
            }
        }
        guard !quads.isEmpty else { return nil }
        return WPETextBlockLayout(
            quads: quads,
            blockWidth: blockWidth,
            lineCount: lines.count,
            metrics: metrics
        )
    }

    /// Splits on authored newlines, then wraps each paragraph to `maxWidth`.
    private static func brokenLines(
        text: String,
        font: CTFont,
        letterSpacing: Double,
        maxWidth: Double?
    ) -> [String] {
        let paragraphs = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let maxWidth, maxWidth > 0 else { return paragraphs }
        var lines: [String] = []
        for paragraph in paragraphs {
            guard !paragraph.isEmpty else {
                lines.append("")
                continue
            }
            let attributed = attributedLine(paragraph, font: font, letterSpacing: letterSpacing)
            let typesetter = CTTypesetterCreateWithAttributedString(attributed)
            let utf16 = Array(paragraph.utf16)
            var start = 0
            while start < utf16.count {
                let count = CTTypesetterSuggestLineBreak(typesetter, start, Double(maxWidth))
                guard count > 0 else { break }
                lines.append(String(utf16CodeUnits: Array(utf16[start..<min(start + count, utf16.count)]), count: min(count, utf16.count - start)))
                start += count
            }
        }
        return lines
    }

    private struct LineGlyph {
        let glyph: CGGlyph
        let runFont: CTFont
        /// Integral raster box around the pen (pure bearings, +y up).
        let cell: CGRect
        /// Pen x within the line (baseline y folds in later per line).
        let penX: Double
    }

    /// One line → glyphs in pen space (pen starts at x=0, baseline y=0, +y up)
    /// plus the line's typographic width. Cells are integer-aligned the way
    /// WPE's FreeType path lands on whole pixels.
    private static func layoutLine(
        _ line: String,
        font: CTFont,
        letterSpacing: Double
    ) -> (quads: [LineGlyph], width: Double) {
        guard !line.isEmpty else { return ([], 0) }
        let attributed = attributedLine(line, font: font, letterSpacing: letterSpacing)
        let ctLine = CTLineCreateWithAttributedString(attributed)
        let width = CTLineGetTypographicBounds(ctLine, nil, nil, nil)
        var quads: [LineGlyph] = []
        for run in (CTLineGetGlyphRuns(ctLine) as? [CTRun]) ?? [] {
            let glyphCount = CTRunGetGlyphCount(run)
            guard glyphCount > 0 else { continue }
            let range = CFRange(location: 0, length: glyphCount)
            var glyphs = [CGGlyph](repeating: 0, count: glyphCount)
            var positions = [CGPoint](repeating: .zero, count: glyphCount)
            CTRunGetGlyphs(run, range, &glyphs)
            CTRunGetPositions(run, range, &positions)
            let runFont = Self.runFont(run) ?? font
            var bounds = [CGRect](repeating: .zero, count: glyphCount)
            CTFontGetBoundingRectsForGlyphs(runFont, .horizontal, glyphs, &bounds, glyphCount)
            for index in 0..<glyphCount {
                let bb = bounds[index]
                guard bb.width > 0, bb.height > 0 else { continue }
                // Integral raster box in GLYPH space (floor/ceil around the
                // bearings) — the atlas rasterizes this exact box, so quad and
                // texels stay 1:1 wherever the quad lands.
                let x0 = Double(bb.minX).rounded(.down)
                let y0 = Double(bb.minY).rounded(.down)
                let x1 = Double(bb.maxX).rounded(.up)
                let y1 = Double(bb.maxY).rounded(.up)
                quads.append(LineGlyph(
                    glyph: glyphs[index],
                    runFont: runFont,
                    cell: CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0),
                    penX: Double(positions[index].x)
                ))
            }
        }
        return (quads, width)
    }

    private static func attributedLine(
        _ line: String,
        font: CTFont,
        letterSpacing: Double
    ) -> CFAttributedString {
        var attributes: [CFString: Any] = [kCTFontAttributeName: font]
        if letterSpacing != 0 {
            // Authored in points like `pointsize` (no corpus sample authors a
            // non-zero value; unit unverified against the oracle).
            attributes[kCTKernAttributeName] = letterSpacing * pixelsPerPoint
        }
        return CFAttributedStringCreate(nil, line as CFString, attributes as CFDictionary)!
    }

    private static func runFont(_ run: CTRun) -> CTFont? {
        let attributes = CTRunGetAttributes(run) as NSDictionary
        guard let value = attributes[kCTFontAttributeName as String] else { return nil }
        if CFGetTypeID(value as CFTypeRef) == CTFontGetTypeID() {
            return (value as! CTFont)
        }
        return nil
    }
}
#endif
