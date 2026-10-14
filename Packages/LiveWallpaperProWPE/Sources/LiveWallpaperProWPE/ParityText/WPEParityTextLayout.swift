import CHarfBuzz
import Foundation

public enum WPEParityTextHorizontalAlign: Sendable {
    case left
    case center
    case right
}

public enum WPEParityTextVerticalAlign: Sendable {
    case top
    case center
    case bottom
}

/// The text object fields WPE's layout reads (140256f20.c:129-265). The caller fills it from the scene.
public struct WPEParityTextLayoutInput: Equatable, Sendable {
    public var text: String
    public var fontPath: String
    public var pointSize: Float
    public var padding: SIMD2<Float>
    public var spacing: SIMD2<Float>
    /// Wrap width in pixels; 0 or less never wraps (WPE passes 0 while `limitwidth` is off).
    public var maxWidth: Float
    public var maxRows: Int
    public var limitRows: Bool
    public var limitUseEllipsis: Bool
    public var blockAlign: Bool
    public var horizontalAlign: WPEParityTextHorizontalAlign
    public var verticalAlign: WPEParityTextVerticalAlign
    /// Effect count ≥ 1, bit4 or opaquebackground: only then does the padding widen the FBO.
    public var appliesPadding: Bool
    /// Actual prepared draw mode, supplied only after the caller admits the matching font material.
    public var glyphMode: WPEParityTextGlyphMode

    public init(
        text: String,
        fontPath: String = "systemfont_arial",
        pointSize: Float = 32,
        padding: SIMD2<Float> = SIMD2(32, 32),
        spacing: SIMD2<Float> = .zero,
        maxWidth: Float = 0,
        maxRows: Int = 1,
        limitRows: Bool = false,
        limitUseEllipsis: Bool = false,
        blockAlign: Bool = false,
        horizontalAlign: WPEParityTextHorizontalAlign = .center,
        verticalAlign: WPEParityTextVerticalAlign = .center,
        appliesPadding: Bool = false,
        glyphMode: WPEParityTextGlyphMode = .bitmap
    ) {
        self.text = text
        self.fontPath = fontPath
        self.pointSize = pointSize
        self.padding = padding
        self.spacing = spacing
        self.maxWidth = maxWidth
        self.maxRows = maxRows
        self.limitRows = limitRows
        self.limitUseEllipsis = limitUseEllipsis
        self.blockAlign = blockAlign
        self.horizontalAlign = horizontalAlign
        self.verticalAlign = verticalAlign
        self.appliesPadding = appliesPadding
        self.glyphMode = glyphMode
    }
}

/// One glyph-quad corner: position in pixels (y up) and atlas UV.
public struct WPEParityTextVertex: Hashable, Sendable {
    public var x: Float
    public var y: Float
    public var z: Float
    public var u: Float
    public var v: Float

    public init(x: Float, y: Float, z: Float, u: Float, v: Float) {
        self.x = x
        self.y = y
        self.z = z
        self.u = u
        self.v = v
    }
}

/// Four vertices and six indices per glyph (1401b0410.c:579-638).
public struct WPEParityTextGlyphMesh: Hashable, Sendable {
    public var vertices: [WPEParityTextVertex] = []
    public var indices: [UInt16] = []
    /// Per quad: the face's index in the font chain << 24 | glyph id. The atlas fills the quad's UVs from it.
    public var glyphKeys: [UInt32] = []
    /// Reset epoch in which these keys acquired references. A stale mesh keeps this alongside its old UVs.
    public var atlasResetGeneration: UInt64?

    mutating func appendQuad(key: UInt32, x0: Float, x1: Float, top: Float, bottom: Float) {
        let base = UInt16(truncatingIfNeeded: glyphKeys.count * 4)
        vertices += [
            WPEParityTextVertex(x: x0, y: top, z: 0, u: 0, v: 0),
            WPEParityTextVertex(x: x1, y: top, z: 0, u: 0, v: 0),
            WPEParityTextVertex(x: x0, y: bottom, z: 0, u: 0, v: 0),
            WPEParityTextVertex(x: x1, y: bottom, z: 0, u: 0, v: 0),
        ]
        indices += [base, base | 2, base | 1, base | 1, base | 2, base | 3]
        glyphKeys.append(key)
    }
}

/// WPE's text mesh: grey and color glyphs in separate lists plus the fields at mesh +0x90..+0xa8.
public struct WPEParityTextMesh: Hashable, Sendable {
    public var mono = WPEParityTextGlyphMesh()
    public var color = WPEParityTextGlyphMesh()
    public var minX: Float
    public var bottom: Float
    public var maxX: Float
    public var top: Float
    public var lineHeight: Float
    public var lineCount: Int
    public var pointSize: Float
    public var glyphMode: WPEParityTextGlyphMode = .bitmap
}

public struct WPEParityTextLayout: Hashable, Sendable {
    /// Nil when nothing produced a glyph; WPE then has no mesh.
    public var mesh: WPEParityTextMesh?
    /// The layer's +0x2f8/+0x2fc translation (140256f20.c:302-325).
    public var blockOffset: SIMD2<Float>
    /// N/140258ab0.c:17-38.
    public var fboSize: SIMD2<Int>
}

/// WPE 2.8.42's text layout, FUN_1401b0410, with the alignment offsets of FUN_140256f20.
public enum WPEParityTextLayoutEngine {
    public static func layout(_ input: WPEParityTextLayoutInput, fonts: WPEParityFontLibrary) -> WPEParityTextLayout {
        let empty = WPEParityTextLayout(mesh: nil, blockOffset: .zero, fboSize: SIMD2(1, 1))
        let scalars = input.text.unicodeScalars.prefix { $0.value != 0 }.map(\.value)
        guard !scalars.isEmpty else { return empty }
        let chain = fonts.chain(fontPath: input.fontPath, pointSize: input.pointSize)
        guard let primary = chain.faces.first else { return empty }
        var layouter = WPEParityTextLayouter(input: input, chain: chain, scalars: scalars.filter { $0 != 13 })
        guard let mesh = layouter.run() else { return empty }
        return WPEParityTextLayout(
            mesh: mesh,
            blockOffset: blockOffset(mesh, primary: primary, input: input),
            fboSize: fboSize(mesh, input: input)
        )
    }

    static func blockOffset(_ mesh: WPEParityTextMesh, primary: WPEParityFontFace, input: WPEParityTextLayoutInput)
        -> SIMD2<Float> {
        let halfWidth = (mesh.maxX - mesh.minX) * 0.5
        let x: Float = switch input.horizontalAlign {
        case .left: halfWidth
        case .center: 0
        case .right: 0 - halfWidth
        }
        let centre = mesh.top - (mesh.top - mesh.bottom) * 0.5
        let rowsBelowFirst = Float(mesh.lineCount) - 1
        let anchor: Float = switch input.verticalAlign {
        case .top: Float(primary.ascender)
        case .center: (Float(primary.ascender) - rowsBelowFirst * mesh.lineHeight) * 0.5
        case .bottom: Float(primary.descender) - rowsBelowFirst * mesh.lineHeight
        }
        return SIMD2(x, centre - anchor)
    }

    static func fboSize(_ mesh: WPEParityTextMesh, input: WPEParityTextLayoutInput) -> SIMD2<Int> {
        let padding = input.appliesPadding ? SIMD2(min(input.padding.x, 512), min(input.padding.y, 512)) : .zero
        return SIMD2(
            Int(padding.x + padding.x + (mesh.maxX - mesh.minX)),
            Int(padding.y + padding.y + (mesh.top - mesh.bottom))
        )
    }
}

/// One FUN_1401b0410 pass. Lines are UTF-32; clusters index into a line.
private struct WPEParityTextLayouter {
    private struct Glyph {
        var faceIndex: Int
        var gid: UInt32
        var isColor: Bool
        var safeToBreak: Bool
        var codepoint: UInt32
        var cluster: Int
        var advance: Float
        var yAdvance: Float
        var x0: Float
        var y0: Float
        var x1: Float
        var y1: Float
        var quadPadding: Float
    }

    private struct Run {
        var text: [UInt32]
        var start: Int
        var faceIndex: Int
        var glyphs: [Glyph] = []
    }

    private struct Line {
        var text: [UInt32]
        var wrapped = false
    }

    private struct LaidLine {
        var width: Float
        var runs: [Run]
    }

    private enum Pass {
        case redo
        case laid([Run])
    }

    private static let ellipsis: UInt32 = 0x2026

    private let input: WPEParityTextLayoutInput
    private let chain: WPEParityFontChain
    private let maxRows: Int
    private var lines: [Line] = []

    init(input: WPEParityTextLayoutInput, chain: WPEParityFontChain, scalars: [UInt32]) {
        self.input = input
        self.chain = chain
        maxRows = input.limitRows ? input.maxRows : 0
        splitLines(scalars)
    }

    /// Tab, CR and space: the characters wrapping, trimming and blockalign treat as blanks.
    private static func isBlank(_ scalar: UInt32) -> Bool {
        scalar == 9 || scalar == 13 || scalar == 32
    }

    /// FUN_1401b0360: drop trailing blanks, then end with U+2026 when ellipsis is on.
    private static func trimTrailing(_ text: inout [UInt32], ellipsis: Bool) {
        while let last = text.last, isBlank(last) {
            text.removeLast()
        }
        if ellipsis, text.last != Self.ellipsis {
            text.append(Self.ellipsis)
        }
    }

    /// 1401b0410.c:383-452: one line per '\n' (none after a trailing one), at most maxRows of them.
    private mutating func splitLines(_ scalars: [UInt32]) {
        guard !scalars.isEmpty else { return }
        var start = 0
        while true {
            let end = scalars[start...].firstIndex(of: 10) ?? scalars.count
            if maxRows > 0, lines.count >= maxRows {
                Self.trimTrailing(&lines[lines.count - 1].text, ellipsis: input.limitUseEllipsis)
                lines[lines.count - 1].wrapped = false
                return
            }
            lines.append(Line(text: Array(scalars[start ..< end])))
            start = end + 1
            if start >= scalars.count {
                return
            }
        }
    }

    mutating func run() -> WPEParityTextMesh? {
        guard let primary = chain.faces.first else { return nil }
        let lineHeight = Float(primary.height) + input.spacing.y
        var laid: [LaidLine] = []
        var minX: Float = 0
        var maxX: Float = 0
        var bottom: Float = 0
        var top: Float = 0
        var widest: Float = 0
        var index = 0
        while index < lines.count {
            guard case var .laid(runs) = layLine(index, finishedLines: laid.count) else { continue }
            let glyphs = runs.flatMap(\.glyphs)
            var lineMinX: Float = 0
            var lineMinY: Float = 0
            var lineMaxX: Float = 0
            var lineMaxY: Float = 0
            var penX: Float = 0
            var penY: Float = 0
            for glyph in glyphs {
                lineMinX = min(lineMinX, penX + glyph.x0)
                lineMinY = min(lineMinY, penY + glyph.y0)
                lineMaxX = max(lineMaxX, penX + glyph.x1)
                lineMaxY = max(lineMaxY, penY + glyph.y1)
                penX += glyph.advance
                penY += glyph.yAdvance
            }
            let line = lines[index]
            let blanks = line.text.filter(Self.isBlank).count
            if input.blockAlign, line.wrapped, blanks > 0 {
                let extra = (input.maxWidth - (lineMaxX - lineMinX)) / Float(blanks)
                for runIndex in runs.indices {
                    for glyphIndex in runs[runIndex].glyphs.indices
                        where Self.isBlank(runs[runIndex].glyphs[glyphIndex].codepoint) {
                        runs[runIndex].glyphs[glyphIndex].advance += extra
                    }
                }
                lineMaxX = lineMinX + input.maxWidth
            }
            let rowOffset = Float(laid.count) * -lineHeight
            bottom = min(bottom, rowOffset + lineMinY)
            top = max(top, rowOffset + lineMaxY)
            let width = lineMaxX - lineMinX
            laid.append(LaidLine(width: width, runs: runs))
            minX = min(minX, lineMinX)
            maxX = max(maxX, lineMaxX)
            widest = max(widest, width)
            index += 1
        }
        guard laid.contains(where: { $0.runs.contains { !$0.glyphs.isEmpty } }) else { return nil }

        let ascender = Float(primary.ascender)
        var mesh = WPEParityTextMesh(
            minX: minX,
            bottom: min(ascender - Float(laid.count) * lineHeight, bottom),
            maxX: maxX,
            top: max(ascender, top),
            lineHeight: lineHeight,
            lineCount: laid.count,
            pointSize: chain.pointSize,
            glyphMode: input.glyphMode
        )
        var lineY: Float = 0
        for line in laid {
            let offset: Float = switch input.horizontalAlign {
            case .left: 0
            case .center: (widest - line.width) * 0.5
            case .right: widest - line.width
            }
            var pen: Float = 0
            for glyph in line.runs.flatMap(\.glyphs) {
                let key = UInt32(glyph.faceIndex) << 24 | glyph.gid
                // 1401b0410 expands only the written quad, after measuring/wrapping unexpanded ink.
                let x0 = ((pen + glyph.x0) - glyph.quadPadding) + offset
                let x1 = pen + glyph.x1 + glyph.quadPadding + offset
                let top = lineY + glyph.y1 + glyph.quadPadding
                let bottom = (lineY + glyph.y0) - glyph.quadPadding
                if glyph.isColor {
                    mesh.color.appendQuad(key: key, x0: x0, x1: x1, top: top, bottom: bottom)
                } else {
                    mesh.mono.appendQuad(key: key, x0: x0, x1: x1, top: top, bottom: bottom)
                }
                pen += glyph.advance
            }
            lineY -= lineHeight
        }
        return mesh
    }

    /// Shapes line `index` run by run, wrapping, eliding or cutting it when a glyph's ink crosses maxWidth
    /// (1401b0410.c:884-1007). `.redo` means the stored line text changed and must be laid out again.
    private mutating func layLine(_ index: Int, finishedLines: Int) -> Pass {
        let text = lines[index].text
        var runs = splitRuns(text)
        var lineGlyphs = 0
        var lastCluster = -1
        var pen: Float = 0
        var runIndex = 0
        while runIndex < runs.count {
            let run = runs[runIndex]
            let face = chain.faces[run.faceIndex]
            for (info, position) in shape(run) {
                guard info.codepoint != 0, let rendered = face.layoutGlyph(info.codepoint, mode: input.glyphMode) else { continue }
                let xOffset = position.x_offset >> 6
                let yOffset = position.y_offset >> 6
                let glyph = Glyph(
                    faceIndex: run.faceIndex,
                    gid: info.codepoint,
                    isColor: rendered.isColor,
                    safeToBreak: info.mask & HB_GLYPH_FLAG_UNSAFE_TO_BREAK.rawValue == 0,
                    codepoint: run.text[Int(info.cluster)],
                    cluster: run.start + Int(info.cluster),
                    advance: Float(position.x_advance >> 6) + input.spacing.x,
                    yAdvance: Float(position.y_advance >> 6),
                    x0: Float(rendered.box.xMin + xOffset),
                    y0: Float(rendered.box.yMin + yOffset),
                    x1: Float(rendered.box.xMax + xOffset),
                    y1: Float(rendered.box.yMax + yOffset),
                    quadPadding: rendered.quadPadding
                )
                if input.maxWidth > 0, lineGlyphs != 0, !Self.isBlank(glyph.codepoint), glyph.cluster != lastCluster,
                   input.maxWidth < glyph.x1 + pen {
                    runs.removeSubrange((runIndex + 1)...)
                    if maxRows < 1 || finishedLines + 1 < maxRows {
                        return wrap(index, text: text, at: glyph.cluster, runs: runs)
                    }
                    let redo = input.limitUseEllipsis && elide(index, text: text, at: glyph.cluster)
                    lines[index].wrapped = false
                    dropRowsBeyondMax()
                    return redo ? .redo : .laid(runs)
                }
                runs[runIndex].glyphs.append(glyph)
                lastCluster = glyph.cluster
                pen += glyph.advance
                lineGlyphs += 1
            }
            runIndex += 1
        }
        return .laid(runs)
    }

    /// Break at the last blank before `cluster` (or at `cluster`), move the rest to a new line, and drop the glyphs
    /// past the trimmed end (1401b0410.c:1215-1469).
    private mutating func wrap(_ index: Int, text: [UInt32], at cluster: Int, runs: [Run]) -> Pass {
        let breakIndex = text[..<cluster].lastIndex(where: Self.isBlank) ?? cluster
        var kept = Array(text[..<breakIndex])
        while let last = kept.last, Self.isBlank(last) {
            kept.removeLast()
        }
        lines[index] = Line(text: kept, wrapped: true)
        lines.insert(Line(text: Array(text[breakIndex...].drop(while: Self.isBlank))), at: index + 1)

        var runs = runs
        var reshape = false
        while var run = runs.popLast() {
            if kept.count <= run.start {
                continue
            }
            let keep = kept.count - run.start
            run.text = Array(run.text.prefix(keep))
            var lastDroppedIsSafe = true
            while let glyph = run.glyphs.last, glyph.cluster - run.start >= keep {
                lastDroppedIsSafe = glyph.safeToBreak
                run.glyphs.removeLast()
            }
            reshape = !run.glyphs.isEmpty && !lastDroppedIsSafe
            runs.append(run)
            break
        }
        dropRowsBeyondMax()
        return reshape ? .redo : .laid(runs)
    }

    /// The longest prefix whose "prefix…" ink right edge fits maxWidth, spacing.x excluded (1401b0410.c:1486-1698).
    /// Returns whether the stored line changed.
    private mutating func elide(_ index: Int, text: [UInt32], at cluster: Int) -> Bool {
        var cut = cluster
        while cut > 0, inkRight(Array(text.prefix(cut)) + [Self.ellipsis]) > input.maxWidth {
            cut -= 1
        }
        var elided = Array(text.prefix(cut))
        guard let last = elided.last, last != Self.ellipsis else { return false }
        while let last = elided.last, Self.isBlank(last) {
            elided.removeLast()
        }
        elided.append(Self.ellipsis)
        // WPE would relay the same text forever when spacing.x pushes it back over; cut it there instead.
        guard elided != text else { return false }
        lines[index].text = elided
        return true
    }

    /// Right ink edge of the last glyph, with the pen advanced by x_advance >> 6 only.
    private func inkRight(_ text: [UInt32]) -> Float {
        var pen: Float = 0
        var right: Float = 0
        for run in splitRuns(text) {
            let face = chain.faces[run.faceIndex]
            for (info, position) in shape(run) {
                guard let box = face.layoutGlyph(info.codepoint, mode: input.glyphMode)?.box else { continue }
                right = Float(position.x_offset >> 6) + pen + Float(box.xMax)
                pen += Float(position.x_advance >> 6)
            }
        }
        return right
    }

    /// 1401b0410.c:1706-1722.
    private mutating func dropRowsBeyondMax() {
        guard maxRows >= 1, maxRows < lines.count else { return }
        lines.removeSubrange(maxRows...)
        Self.trimTrailing(&lines[maxRows - 1].text, ellipsis: input.limitUseEllipsis)
        lines[maxRows - 1].wrapped = false
    }

    /// FUN_1401ad670: a new run starts at a non-blank, non-ZWJ character whose first covering face differs from
    /// the current run's. Blanks before the first run are dropped; characters no face has stay in the current run.
    private func splitRuns(_ text: [UInt32]) -> [Run] {
        var runs: [Run] = []
        var current: Int?
        var start = 0
        for (index, scalar) in text.enumerated() {
            guard let face = chain.faceIndex(containing: scalar), face != current, scalar != 0x200D,
                  !Self.isBlank(scalar), scalar != 10 else { continue }
            if let current, start < index {
                runs.append(Run(text: Array(text[start ..< index]), start: start, faceIndex: current))
            }
            current = face
            start = index
        }
        if let current, start < text.count {
            runs.append(Run(text: Array(text[start...]), start: start, faceIndex: current))
        }
        return runs
    }

    /// One hb_shape per run: guessed segment properties, no features (1401b0410.c:870-905).
    private func shape(_ run: Run) -> [(hb_glyph_info_t, hb_glyph_position_t)] {
        let buffer = hb_buffer_create()
        defer { hb_buffer_destroy(buffer) }
        run.text.withUnsafeBufferPointer { text in
            hb_buffer_add_utf32(buffer, text.baseAddress, Int32(text.count), 0, -1)
        }
        hb_buffer_guess_segment_properties(buffer)
        hb_shape(chain.faces[run.faceIndex].font, buffer, nil, 0)
        var count: UInt32 = 0
        guard let infos = hb_buffer_get_glyph_infos(buffer, &count),
              let positions = hb_buffer_get_glyph_positions(buffer, nil) else { return [] }
        return (0 ..< Int(count)).map { (infos[$0], positions[$0]) }
    }
}
