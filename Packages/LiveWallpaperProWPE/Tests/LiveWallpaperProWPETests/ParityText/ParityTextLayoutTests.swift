import Foundation
@testable import LiveWallpaperProWPE
import XCTest

/// Golden values for NotoSans-Regular at 32 pt and 300 dpi, worked out by hand from the WPE layout rules.
/// Advances are hb x_advance >> 6; boxes are the hinted FreeType cbox in pixels (xMin, yMin, xMax, yMax).
final class ParityTextLayoutTests: XCTestCase {
    private struct Glyph {
        let gid: UInt32
        let advance: Float
        let x0: Float, y0: Float, x1: Float, y1: Float
    }

    private static let ascender: Float = 143
    private static let descender: Float = -40
    private static let lineHeight: Float = 182

    private static let capitalH = Glyph(gid: 43, advance: 98, x0: 12, y0: 0, x1: 86, y1: 95)
    private static let smallE = Glyph(gid: 72, advance: 75, x0: 7, y0: -1, x1: 69, y1: 73)
    private static let smallL = Glyph(gid: 79, advance: 34, x0: 11, y0: 0, x1: 24, y1: 102)
    private static let smallO = Glyph(gid: 82, advance: 80, x0: 7, y0: -1, x1: 74, y1: 73)
    /// "o" kerned against a following "w".
    private static let smallOBeforeW = Glyph(gid: 82, advance: 77, x0: 7, y0: -1, x1: 74, y1: 73)
    private static let comma = Glyph(gid: 15, advance: 35, x0: 5, y0: -17, x1: 26, y1: 16)
    private static let space = Glyph(gid: 3, advance: 34, x0: 0, y0: 0, x1: 0, y1: 0)
    private static let capitalW = Glyph(gid: 58, advance: 121, x0: 1, y0: 0, x1: 123, y1: 95)
    private static let smallW = Glyph(gid: 90, advance: 104, x0: 1, y0: 0, x1: 104, y1: 72)
    private static let smallR = Glyph(gid: 85, advance: 55, x0: 11, y0: 0, x1: 54, y1: 73)
    private static let smallD = Glyph(gid: 71, advance: 82, x0: 7, y0: -1, x1: 71, y1: 102)
    private static let smallB = Glyph(gid: 69, advance: 82, x0: 11, y0: -1, x1: 75, y1: 102)
    private static let smallI = Glyph(gid: 76, advance: 34, x0: 10, y0: 0, x1: 25, y1: 99)
    private static let smallG = Glyph(gid: 74, advance: 82, x0: 7, y0: -32, x1: 71, y1: 73)
    private static let ellipsis = Glyph(gid: 527, advance: 105, x0: 9, y0: -1, x1: 96, y1: 17)
    private static let capitalA = Glyph(gid: 36, advance: 85, x0: 0, y0: 0, x1: 86, y1: 95)
    private static let smallX = Glyph(gid: 91, advance: 70, x0: 2, y0: 0, x1: 69, y1: 72)

    private static let hello = [capitalH, smallE, smallL, smallL, smallO]
    private static let world = [capitalW, smallO, smallR, smallL, smallD]

    private func input(
        _ text: String,
        maxWidth: Float = 0,
        horizontal: WPEParityTextHorizontalAlign = .left,
        vertical: WPEParityTextVerticalAlign = .top
    ) -> WPEParityTextLayoutInput {
        WPEParityTextLayoutInput(
            text: text,
            fontPath: ParityFontChainTests.notoSans,
            pointSize: 32,
            maxWidth: maxWidth,
            horizontalAlign: horizontal,
            verticalAlign: vertical
        )
    }

    private func layout(_ input: WPEParityTextLayoutInput) throws -> WPEParityTextLayout {
        try WPEParityTextLayoutEngine.layout(input, fonts: ParityFontChainTests.makeLibrary())
    }

    /// Left edge of each quad minus its glyph's ink left edge, i.e. the pen plus the line offset.
    private func pens(_ mesh: WPEParityTextMesh, _ glyphs: [Glyph]) -> [Float] {
        zip(0 ..< glyphs.count, glyphs).map { mesh.mono.vertices[$0 * 4].x - $1.x0 }
    }

    private func gids(_ mesh: WPEParityTextMesh) -> [UInt32] {
        mesh.mono.glyphKeys.map { $0 & 0xFFFFFF }
    }

    private func cumulative(_ glyphs: [Glyph], spacing: Float = 0) -> [Float] {
        var pen: Float = 0
        return glyphs.map { glyph in
            defer { pen += glyph.advance + spacing }
            return pen
        }
    }

    func testSingleLinePenPositionsWithSpacing() throws {
        let spacingX: Float = 3
        var request = input("Hello, World")
        request.spacing = SIMD2(spacingX, 0)
        let mesh = try XCTUnwrap(layout(request).mesh)
        let glyphs = Self.hello + [Self.comma, Self.space] + Self.world
        let expectedPens = cumulative(glyphs, spacing: spacingX)

        XCTAssertEqual(mesh.mono.glyphKeys.count, glyphs.count)
        XCTAssertTrue(mesh.color.glyphKeys.isEmpty)
        XCTAssertEqual(gids(mesh), glyphs.map(\.gid))
        XCTAssertEqual(pens(mesh, glyphs), expectedPens)
        XCTAssertEqual(mesh.mono.indices.prefix(12), [0, 2, 1, 1, 2, 3, 4, 6, 5, 5, 6, 7])

        let first = Self.capitalH
        XCTAssertEqual(Array(mesh.mono.vertices.prefix(4)), [
            WPEParityTextVertex(x: first.x0, y: first.y1, z: 0, u: 0, v: 0),
            WPEParityTextVertex(x: first.x1, y: first.y1, z: 0, u: 0, v: 0),
            WPEParityTextVertex(x: first.x0, y: first.y0, z: 0, u: 0, v: 0),
            WPEParityTextVertex(x: first.x1, y: first.y0, z: 0, u: 0, v: 0),
        ])
        let last = Self.smallD
        let lastPen = try XCTUnwrap(expectedPens.last)
        XCTAssertEqual(Array(mesh.mono.vertices.suffix(4)), [
            WPEParityTextVertex(x: lastPen + last.x0, y: last.y1, z: 0, u: 0, v: 0),
            WPEParityTextVertex(x: lastPen + last.x1, y: last.y1, z: 0, u: 0, v: 0),
            WPEParityTextVertex(x: lastPen + last.x0, y: last.y0, z: 0, u: 0, v: 0),
            WPEParityTextVertex(x: lastPen + last.x1, y: last.y0, z: 0, u: 0, v: 0),
        ])

        XCTAssertEqual(mesh.minX, 0)
        XCTAssertEqual(mesh.maxX, lastPen + last.x1)
        XCTAssertEqual(mesh.top, Self.ascender)
        // Bottom is the lower of A - n·lh and the ink bottom (the comma at -17).
        XCTAssertEqual(mesh.bottom, Self.ascender - Self.lineHeight)
        XCTAssertEqual(mesh.lineHeight, Self.lineHeight)
        XCTAssertEqual(mesh.lineCount, 1)
        XCTAssertEqual(mesh.pointSize, 32)
    }

    func testWrapAtMaxWidthBreaksOnTheSpace() throws {
        // "Hello W": the W's ink right edge lands past 400, so the line breaks at the space.
        let maxWidth: Float = 400
        let helloSpace = cumulative(Self.hello + [Self.space])
        XCTAssertGreaterThan(helloSpace[5] + Self.space.advance + Self.capitalW.x1, maxWidth)
        let mesh = try XCTUnwrap(layout(input("Hello World", maxWidth: maxWidth)).mesh)

        XCTAssertEqual(mesh.lineCount, 2)
        XCTAssertEqual(gids(mesh), (Self.hello + Self.world).map(\.gid))
        let worldPens = cumulative(Self.world)
        let wQuad = Array(mesh.mono.vertices[5 * 4 ..< 6 * 4])
        XCTAssertEqual(wQuad[0], WPEParityTextVertex(
            x: Self.capitalW.x0,
            y: -Self.lineHeight + Self.capitalW.y1,
            z: 0,
            u: 0,
            v: 0
        ))
        XCTAssertEqual(wQuad[3].y, -Self.lineHeight + Self.capitalW.y0)
        XCTAssertEqual(mesh.maxX, worldPens[4] + Self.smallD.x1)
        XCTAssertEqual(mesh.bottom, Self.ascender - 2 * Self.lineHeight)
    }

    func testTrailingSpacesOfAWrappedLineAreNotCounted() throws {
        let maxWidth: Float = 400
        let result = try layout(input("Hello   World", maxWidth: maxWidth, horizontal: .center))
        let mesh = try XCTUnwrap(result.mesh)
        let helloWidth = cumulative(Self.hello)[4] + Self.smallO.x1
        let worldWidth = cumulative(Self.world)[4] + Self.smallD.x1

        XCTAssertEqual(gids(mesh), (Self.hello + Self.world).map(\.gid))
        XCTAssertEqual(mesh.maxX, worldWidth)
        // Centred against the wider line; the three spaces add nothing to "Hello".
        XCTAssertEqual(mesh.mono.vertices[0].x, (worldWidth - helloWidth) * 0.5 + Self.capitalH.x0)
    }

    func testOverlongWordBreaksAtACharacter() throws {
        // "Hell|ow|orld": no space to break on, so each line ends before the glyph whose ink crosses 250.
        let maxWidth: Float = 250
        let hell = cumulative(Self.hello)
        XCTAssertGreaterThan(hell[4] + Self.smallO.x1, maxWidth)
        let mesh = try XCTUnwrap(layout(input("Helloworld", maxWidth: maxWidth)).mesh)

        XCTAssertEqual(mesh.lineCount, 3)
        XCTAssertEqual(gids(mesh), [43, 72, 79, 79, 82, 90, 82, 85, 79, 71])
        XCTAssertEqual(mesh.mono.vertices[4 * 4].x, Self.smallO.x0)
        XCTAssertEqual(mesh.mono.vertices[4 * 4].y, -Self.lineHeight + Self.smallO.y1)
        XCTAssertEqual(mesh.mono.vertices[5 * 4].x, Self.smallOBeforeW.advance + Self.smallW.x0)
        XCTAssertEqual(mesh.mono.vertices[6 * 4].y, -2 * Self.lineHeight + Self.smallO.y1)
    }

    func testMaxRowsOneWithoutEllipsisCutsAtTheOverflowingGlyph() throws {
        var request = input("Hello World", maxWidth: 400)
        request.limitRows = true
        request.maxRows = 1
        let mesh = try XCTUnwrap(layout(request).mesh)
        // The hard cut keeps everything before the W, including the space glyph and its pen.
        let pens = cumulative(Self.hello + [Self.space])
        XCTAssertEqual(mesh.lineCount, 1)
        XCTAssertEqual(gids(mesh), (Self.hello + [Self.space]).map(\.gid))
        XCTAssertEqual(mesh.maxX, pens[5])
    }

    func testMaxRowsOneWithEllipsisKeepsTheLongestFittingPrefix() throws {
        let maxWidth: Float = 400
        var request = input("Hello World", maxWidth: maxWidth)
        request.limitRows = true
        request.maxRows = 1
        request.limitUseEllipsis = true
        let mesh = try XCTUnwrap(layout(request).mesh)
        // "Hello …" and "Hello…" overflow by the ellipsis ink right edge; "Hell…" fits.
        let hell = cumulative(Self.hello)
        XCTAssertGreaterThan(hell[4] + Self.smallO.advance + Self.ellipsis.x1, maxWidth)
        XCTAssertLessThanOrEqual(hell[4] + Self.ellipsis.x1, maxWidth)
        XCTAssertEqual(mesh.lineCount, 1)
        XCTAssertEqual(gids(mesh), [43, 72, 79, 79, Self.ellipsis.gid])
        XCTAssertEqual(mesh.maxX, hell[4] + Self.ellipsis.x1)
    }

    func testExplicitLinesBeyondMaxRowsEndInAnEllipsis() throws {
        var request = input("Hello\nWorld")
        request.limitRows = true
        request.maxRows = 1
        request.limitUseEllipsis = true
        let mesh = try XCTUnwrap(layout(request).mesh)
        XCTAssertEqual(mesh.lineCount, 1)
        XCTAssertEqual(gids(mesh), (Self.hello + [Self.ellipsis]).map(\.gid))
    }

    func testBlockAlignSpreadsAWrappedLineToMaxWidth() throws {
        let maxWidth: Float = 600
        var request = input("Hello big World", maxWidth: maxWidth)
        request.blockAlign = true
        let mesh = try XCTUnwrap(layout(request).mesh)
        let firstLine = Self.hello + [Self.space, Self.smallB, Self.smallI, Self.smallG]
        let pens = cumulative(firstLine)
        let inkWidth = pens[8] + Self.smallG.x1
        let extraPerSpace = (maxWidth - inkWidth) / 1

        XCTAssertEqual(mesh.lineCount, 2)
        XCTAssertEqual(gids(mesh), (firstLine + Self.world).map(\.gid))
        XCTAssertEqual(mesh.mono.vertices[6 * 4].x, pens[6] + extraPerSpace + Self.smallB.x0)
        XCTAssertEqual(mesh.maxX, maxWidth)
    }

    func testBlockOffsetsForAllNineAlignments() throws {
        // Two lines of "Hello World" wrapped at 400: minX 0, maxX = "World" ink, top A, bottom A - 2·lh.
        let width = cumulative(Self.world)[4] + Self.smallD.x1
        let top = Self.ascender
        let bottom = Self.ascender - 2 * Self.lineHeight
        let centreY = top - (top - bottom) * 0.5
        let lines: Float = 2
        let expectedX: [WPEParityTextHorizontalAlign: Float] = [.left: width * 0.5, .center: 0, .right: -width * 0.5]
        let expectedY: [WPEParityTextVerticalAlign: Float] = [
            .top: centreY - Self.ascender,
            .center: centreY - (Self.ascender - (lines - 1) * Self.lineHeight) * 0.5,
            .bottom: centreY - (Self.descender - (lines - 1) * Self.lineHeight),
        ]
        for horizontal in [WPEParityTextHorizontalAlign.left, .center, .right] {
            for vertical in [WPEParityTextVerticalAlign.top, .center, .bottom] {
                let result = try layout(input("Hello World", maxWidth: 400, horizontal: horizontal, vertical: vertical))
                XCTAssertEqual(
                    result.blockOffset,
                    try SIMD2(XCTUnwrap(expectedX[horizontal]), XCTUnwrap(expectedY[vertical])),
                    "\(horizontal) \(vertical)"
                )
            }
        }
    }

    func testCharacterNoFaceHasProducesNoQuadAndNoAdvance() throws {
        let mesh = try XCTUnwrap(layout(input("A\u{E000}x")).mesh)
        XCTAssertEqual(gids(mesh), [Self.capitalA.gid, Self.smallX.gid])
        XCTAssertEqual(mesh.mono.vertices[4].x, Self.capitalA.advance + Self.smallX.x0)
    }

    func testCarriageReturnIsRemovedAndTrailingNewlineAddsNoLine() throws {
        let plain = try XCTUnwrap(layout(input("Hello")).mesh)
        let withReturn = try XCTUnwrap(layout(input("Hel\rlo\n")).mesh)
        XCTAssertEqual(withReturn, plain)
        XCTAssertEqual(withReturn.lineCount, 1)
        XCTAssertEqual(try XCTUnwrap(layout(input("Hello\n\n")).mesh).lineCount, 2)
    }

    func testFramebufferSize() throws {
        let width = cumulative(Self.hello + [Self.comma, Self.space] + Self.world)[11] + Self.smallD.x1
        let height = Self.ascender - (Self.ascender - Self.lineHeight)
        var request = input("Hello, World")
        XCTAssertEqual(try layout(request).fboSize, SIMD2(Int(width), Int(height)))

        let padding: Float = 32
        request.padding = SIMD2(padding, padding)
        request.appliesPadding = true
        XCTAssertEqual(try layout(request).fboSize, SIMD2(Int(width + 2 * padding), Int(height + 2 * padding)))

        let paddingCap: Float = 512
        request.padding = SIMD2(600, 10)
        XCTAssertEqual(try layout(request).fboSize, SIMD2(Int(width + 2 * paddingCap), Int(height + 2 * 10)))

        let empty = try layout(input(""))
        XCTAssertNil(empty.mesh)
        XCTAssertEqual(empty.fboSize, SIMD2(1, 1))
        XCTAssertEqual(empty.blockOffset, SIMD2(0, 0))
    }

    func testChineseComesFromAFallbackFace() throws {
        let mesh = try XCTUnwrap(WPEParityTextLayoutEngine.layout(input("你好"), fonts: ParityFontChainTests.makeLibraryWithFixedFallbacks()).mesh)
        let keys = mesh.mono.glyphKeys + mesh.color.glyphKeys
        XCTAssertEqual(keys.count, 2)
        for key in keys {
            XCTAssertGreaterThan(key >> 24, 0, "face index in the chain")
            XCTAssertNotEqual(key & 0xFFFFFF, 0, "gid")
        }
    }

    /// Windows draws ：（） from msyh; Apple Symbols, the seguisym stand-in one slot earlier, must not take them.
    func testFullWidthPunctuationComesFromTheCJKFace() throws {
        let library = try ParityFontChainTests.makeLibraryWithFixedFallbacks()
        let mesh = try XCTUnwrap(WPEParityTextLayoutEngine.layout(input("作：（）　"), fonts: library).mesh)
        let faces = mesh.mono.glyphKeys.map { Int($0 >> 24) }
        let families = library.chain(fontPath: ParityFontChainTests.notoSans, pointSize: 32).faces.map(\.familyName)
        XCTAssertEqual(faces.map { families[$0] }, Array(repeating: "Loomscreen Test CJK", count: 5))
        let symbols = try XCTUnwrap(library.chain(fontPath: ParityFontChainTests.notoSans, pointSize: 32).faces.first {
            $0.familyName == "Loomscreen Test Symbols"
        })
        for scalar in [UInt32(0x3000), 0xFF08, 0xFF09, 0xFF1A] {
            XCTAssertTrue(symbols.hasCharacter(scalar), "The earlier Symbols slot must map the excluded form")
        }
    }

    /// A character no slot maps spends all eight slots, and every slot that loads stays in the chain.
    func testUnmappedCharacterAppendsEverySlotAndLaterCharactersUseThem() throws {
        let library = try ParityFontChainTests.makeLibraryWithFixedFallbacks()
        let mesh = try XCTUnwrap(WPEParityTextLayoutEngine.layout(input("\u{E000}你"), fonts: library).mesh)
        let keys = mesh.mono.glyphKeys + mesh.color.glyphKeys
        XCTAssertEqual(keys.count, 1)
        XCTAssertGreaterThan(try XCTUnwrap(keys.first) >> 24, 0, "face index in the chain")
        XCTAssertEqual(
            library.chain(fontPath: ParityFontChainTests.notoSans, pointSize: 32).faces.map(\.familyName),
            ["Noto Sans", "Noto Sans", "Twemoji Mozilla", "Roboto Mono", "Loomscreen Test Symbols", "Loomscreen Test CJK",
             "Noto Sans"]
        )
    }

    func testEmojiComesFromTwemojiAsAColorGlyph() throws {
        let mesh = try XCTUnwrap(layout(input("H😀")).mesh)
        XCTAssertEqual(gids(mesh), [Self.capitalH.gid])
        XCTAssertEqual(mesh.color.glyphKeys.map { $0 & 0xFFFFFF }, [883])
    }

    func testHeavyHeartComesFromTwemojiAsAColorGlyph() throws {
        let mesh = try XCTUnwrap(layout(input("H\u{2764}")).mesh)
        XCTAssertEqual(gids(mesh), [Self.capitalH.gid])
        XCTAssertEqual(mesh.color.glyphKeys.count, 1)
    }
}
