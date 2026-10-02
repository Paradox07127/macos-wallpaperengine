#if !LITE_BUILD
import CoreGraphics
import CoreText
import Foundation
import simd

/// OS/2 `USE_TYPO_METRICS` (fsSelection bit 7) selects the typo metrics, otherwise hhea metrics apply.
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
    /// Reads head/hhea/OS2 directly: CTFontGetAscent always reports hhea metrics, which mis-sizes USE_TYPO_METRICS fonts.
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
    /// The glyph's own integral raster box relative to its pen (pure bearings, no placement) — what the atlas rasterizes.
    let cell: CGRect
    /// `cell` translated to the glyph's block-local position (pen + line +
    /// alignment offsets), integer-aligned.
    let rect: CGRect
}

/// The placement anchor is the object origin; the authored `size` box does not exist at runtime.
struct WPETextBlockLayout {
    let quads: [WPETextGlyphQuad]
    /// Rightmost glyph ink edge over all lines, measured from the pen start; trailing spacing and spaces are not part of it.
    let blockWidth: Double
    let lineCount: Int
    /// Primary font metrics at em pixels, unrounded.
    let metrics: WPETextLineMetrics
    /// Baseline-to-baseline step: the rounded font line height plus authored `spacing.y`.
    let lineAdvance: Double

    /// FreeType ceils the ascender and floors the descender to whole pixels; the line height is rounded separately, so it is not `ascent + descent`.
    var ascent: Double {
        metrics.ascender.rounded(.up)
    }

    var descent: Double {
        metrics.descender.rounded(.up)
    }

    /// Its top edge sits `ascent` above the first baseline.
    var blockSize: CGSize {
        CGSize(width: blockWidth, height: Double(lineCount) * lineAdvance)
    }

    /// Offset from the object origin to block-local (0,0), author-space pixels (+y up): `world = origin + R·S·(offset + local)`.
    func anchorOffset(horizontalAlignment: String, verticalAlignment: String) -> SIMD2<Double> {
        let x: Double
        switch horizontalAlignment {
        case "left": x = 0
        case "right": x = -blockWidth
        default: x = -blockWidth / 2
        }
        let y: Double = switch verticalAlignment {
        case "top": -ascent
        case "bottom": descent + Double(lineCount - 1) * lineAdvance
        default: -ascent / 2 + Double(lineCount - 1) * lineAdvance / 2
        }
        return SIMD2<Double>(x, y)
    }
}

enum WPETextLayoutEngine {
    /// WPE rasterizes `pointsize` at 300 DPI: author-space pixels per point.
    static let pixelsPerPoint = 300.0 / 72.0

    /// `spacing` is authored canvas px (not scaled by 300/72): x after every glyph advance, y on the line advance. `maxWidth` (author px) wraps when present; `maxRows` clamps the row count (appending `…` when `ellipsis`). Returns nil for empty text.
    static func layout(
        text: String,
        font: CTFont,
        spacing: SIMD2<Double> = .zero,
        horizontalAlignment: String = "center",
        maxWidth: Double? = nil,
        maxRows: Int? = nil,
        ellipsis: Bool = false
    ) -> WPETextBlockLayout? {
        guard !text.isEmpty else { return nil }
        let metrics = WPETextFontMetricsReader.metrics(for: font)
        let lineAdvance = metrics.lineHeight.rounded() + spacing.y

        var lines = brokenLines(text: text, font: font, spacingX: spacing.x, maxWidth: maxWidth)
        if let maxRows, maxRows > 0, lines.count > maxRows {
            lines = Array(lines.prefix(maxRows))
            if ellipsis, var last = lines.last {
                while let tail = last.last, tail.isWhitespace { last.removeLast() }
                lines[lines.count - 1] = last + "\u{2026}"
            }
        }
        guard !lines.isEmpty else { return nil }

        let lineLayouts = lines.map { layoutLine($0, font: font, spacingX: spacing.x) }
        let (blockWidth, indents) = lineIndents(
            inkRights: lineLayouts.map(\.inkRight),
            horizontalAlignment: horizontalAlignment
        )

        var quads: [WPETextGlyphQuad] = []
        for (index, line) in lineLayouts.enumerated() {
            let baselineY = -Double(index) * lineAdvance
            for glyph in line.quads {
                let placed = glyph.cell.offsetBy(dx: glyph.penX + indents[index], dy: baselineY)
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
            metrics: metrics,
            lineAdvance: lineAdvance
        )
    }

    /// `inkRights` are per-line distances from the pen start to the rightmost glyph ink edge. Indents keep half pixels.
    static func lineIndents(
        inkRights: [Double],
        horizontalAlignment: String
    ) -> (blockWidth: Double, lineIndents: [Double]) {
        let blockWidth = inkRights.max() ?? 0
        let indents = inkRights.map { inkRight -> Double in
            switch horizontalAlignment {
            case "left": 0
            case "right": blockWidth - inkRight
            default: (blockWidth - inkRight) / 2
            }
        }
        return (blockWidth, indents)
    }

    private static func brokenLines(
        text: String,
        font: CTFont,
        spacingX: Double,
        maxWidth: Double?
    ) -> [String] {
        // "\r\n" is a single Character in Swift and never equals "\n".
        let paragraphs = text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" })
            .map(String.init)
        guard let maxWidth, maxWidth > 0 else { return paragraphs }
        return paragraphs.flatMap { wrapped($0, font: font, spacingX: spacingX, maxWidth: maxWidth) }
    }

    /// Greedy by word: a line takes the next word while its width up to the last non-space glyph fits `maxWidth`; a word wider than a fresh line breaks per character. Spaces at a wrap point are dropped.
    private static func wrapped(_ paragraph: String, font: CTFont, spacingX: Double, maxWidth: Double) -> [String] {
        let characters = Array(paragraph)
        guard !characters.isEmpty else { return [""] }
        var prefixWidth = [0.0]
        for advance in characterAdvances(paragraph, characters: characters, font: font, spacingX: spacingX) {
            prefixWidth.append(prefixWidth[prefixWidth.count - 1] + advance)
        }
        func fits(_ start: Int, _ end: Int) -> Bool {
            var last = end
            while last > start, characters[last - 1].isWhitespace {
                last -= 1
            }
            guard last > start else { return true }
            return prefixWidth[last] - prefixWidth[start] - spacingX <= maxWidth
        }

        var lines: [String] = []
        // `characters[start ..< end]` is the open line; `end > start` once it holds a whole word.
        var start = 0
        var end = 0
        var cursor = 0
        while cursor < characters.count {
            var wordStart = cursor
            while wordStart < characters.count, characters[wordStart].isWhitespace {
                wordStart += 1
            }
            guard wordStart < characters.count else { break }
            var wordEnd = wordStart
            while wordEnd < characters.count, !characters[wordEnd].isWhitespace {
                wordEnd += 1
            }
            if fits(start, wordEnd) {
                end = wordEnd
                cursor = wordEnd
            } else if end > start {
                lines.append(String(characters[start ..< end]))
                start = wordStart
                end = wordStart
                cursor = wordStart
            } else {
                var cut = wordStart + 1
                while cut < wordEnd, fits(start, cut + 1) {
                    cut += 1
                }
                lines.append(String(characters[start ..< cut]))
                start = cut
                end = cut
                cursor = cut
            }
        }
        if start < characters.count {
            lines.append(String(characters[start...]))
        }
        return lines
    }

    /// Per character: the advances of the glyphs it shapes to, each plus `spacingX`.
    private static func characterAdvances(
        _ paragraph: String,
        characters: [Character],
        font: CTFont,
        spacingX: Double
    ) -> [Double] {
        var characterAtUTF16: [Int] = []
        for (index, character) in characters.enumerated() {
            characterAtUTF16.append(contentsOf: repeatElement(index, count: character.utf16.count))
        }
        var advances = [Double](repeating: 0, count: characters.count)
        let ctLine = CTLineCreateWithAttributedString(attributedLine(paragraph, font: font))
        for run in (CTLineGetGlyphRuns(ctLine) as? [CTRun]) ?? [] {
            let glyphCount = CTRunGetGlyphCount(run)
            guard glyphCount > 0 else { continue }
            let range = CFRange(location: 0, length: glyphCount)
            var glyphAdvances = [CGSize](repeating: .zero, count: glyphCount)
            var stringIndices = [CFIndex](repeating: 0, count: glyphCount)
            CTRunGetAdvances(run, range, &glyphAdvances)
            CTRunGetStringIndices(run, range, &stringIndices)
            for index in 0 ..< glyphCount where characterAtUTF16.indices.contains(stringIndices[index]) {
                advances[characterAtUTF16[stringIndices[index]]] += Double(glyphAdvances[index].width) + spacingX
            }
        }
        return advances
    }

    private struct LineGlyph {
        let glyph: CGGlyph
        let runFont: CTFont
        /// Integral raster box around the pen (pure bearings, +y up).
        let cell: CGRect
        /// Pen x within the line (baseline y folds in later per line).
        let penX: Double
    }

    /// Pen starts at x=0, baseline y=0, +y up; each glyph sits `spacingX` further per glyph left of it. Cells are integer-aligned the way WPE's FreeType path lands on whole pixels.
    private static func layoutLine(
        _ line: String,
        font: CTFont,
        spacingX: Double
    ) -> (quads: [LineGlyph], inkRight: Double) {
        guard !line.isEmpty else { return ([], 0) }
        let ctLine = CTLineCreateWithAttributedString(attributedLine(line, font: font))
        var shaped: [(x: Double, glyph: CGGlyph, runFont: CTFont, bounds: CGRect)] = []
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
                shaped.append((Double(positions[index].x), glyphs[index], runFont, bounds[index]))
            }
        }
        // Spaces count toward the per-glyph spacing even though they emit no quad.
        let visualOrder = shaped.indices.sorted { (shaped[$0].x, $0) < (shaped[$1].x, $1) }
        var quads: [LineGlyph] = []
        var inkRight = 0.0
        for (rank, index) in visualOrder.enumerated() {
            let entry = shaped[index]
            let bb = entry.bounds
            guard bb.width > 0, bb.height > 0 else { continue }
            // Integral raster box in glyph space (floor/ceil around the bearings) — the atlas rasterizes this exact box, so quad and texels stay 1:1.
            let x0 = Double(bb.minX).rounded(.down)
            let y0 = Double(bb.minY).rounded(.down)
            let x1 = Double(bb.maxX).rounded(.up)
            let y1 = Double(bb.maxY).rounded(.up)
            let penX = entry.x + Double(rank) * spacingX
            quads.append(LineGlyph(
                glyph: entry.glyph,
                runFont: entry.runFont,
                cell: CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0),
                penX: penX
            ))
            inkRight = max(inkRight, penX + x1)
        }
        return (quads, inkRight)
    }

    private static func attributedLine(_ line: String, font: CTFont) -> CFAttributedString {
        CFAttributedStringCreate(nil, line as CFString, [kCTFontAttributeName: font] as CFDictionary)!
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
